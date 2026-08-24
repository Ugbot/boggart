-- vim.lua -- neovim-style modal editing for the studio code editor.
--
-- A modal LAYER over the existing lite-xl editing engine, not a rewrite: it
-- reuses the motions in core.doc.translate, the selection API on Doc, and the
-- doc:* command family. Two mechanisms make it work without forking the core:
--
--   1. Characters arrive through DocView:on_text_input (which we wrap). In any
--      mode but insert we swallow the character and feed it to the grammar,
--      so the actual glyph -- "$", "%", "}" -- reaches us regardless of the
--      keyboard layout. Insert mode falls through to the normal typing path.
--   2. The handful of non-printable keys that are bound to destructive doc
--      commands (backspace, delete, return, tab) get vim commands PREPENDED in
--      the keymap, gated to non-insert mode, so in normal mode they move rather
--      than mutate, and in insert mode they fall through to their defaults.
--
-- State lives on each real DocView (dv.vim). CommandView extends DocView but is
-- deliberately excluded (getmetatable ~= DocView) so ':' and '/' still type.

local core = require "core"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local search = require "core.doc.search"
local DocView = require "core.docview"
local style = require "core.style"

local M = {}

M.enabled = config.vim_mode == true
M.register = { text = "", linewise = false } -- the unnamed register
M.registers = {}                             -- named registers, keyed by a-z
M.active_reg = nil                           -- register selected for this command
M.last_find = nil -- { type = "f"|"F"|"t"|"T", char = "x" }

-- Dot-repeat records the keystrokes of the last buffer-changing command and
-- replays them verbatim. See M.on_char / M.dot_repeat.
M.last_change_keys = nil
M.rec_active = false
M.rec = ""
M.rec_is_change = false
M.replaying = false

local function mark_change()
  if M.rec_active and not M.replaying then M.rec_is_change = true end
end


-- ---- per-DocView state -----------------------------------------------------

-- Only genuine editor DocViews get modal state. CommandView (the ':'/'/' line)
-- extends DocView, so the metatable check keeps it modeless.
local function vstate(dv)
  if getmetatable(dv) ~= DocView then return nil end
  if not dv.vim then
    dv.vim = { mode = "normal", count = "", op = nil, opcount = "",
               await = nil, gpend = false, reg = nil, textobj = nil }
  end
  return dv.vim
end
M.state = vstate

-- The modal spine (shell/modal.lua) asks every focused view whether it is a
-- text input right now. A DocView answers through vim: in normal mode it is a
-- viewport the spine's j/k should drive; in insert mode -- or with vim disabled,
-- a modeless editor -- it is a text field that owns every key.
function DocView:is_text_input()
  if M.enabled and M.state then
    local st = M.state(self)
    return not st or st.mode == "insert"
  end
  return true
end

local function reset(v)
  v.count, v.op, v.opcount, v.await, v.gpend = "", nil, "", nil, false
  v.reg, v.textobj = nil, nil
end

-- The effective repeat count: the product of a count typed before the operator
-- and one typed after it (vim's "2d3w" == 6). Defaults to 1.
local function eff_count(v)
  local a, b = tonumber(v.count), tonumber(v.opcount)
  if not a and not b then return 1 end
  return (a or 1) * (b or 1)
end

local function had_count(v)
  return v.count ~= "" or v.opcount ~= ""
end


-- ---- registers -------------------------------------------------------------

function M.set_register(text, linewise)
  local rec = { text = text, linewise = linewise }
  M.register = rec
  if M.active_reg then M.registers[M.active_reg] = rec end
  -- Mirror to the system clipboard for linewise yanks too (yy/dd): skipping them
  -- meant a whole-line yank never left the app, so Cmd-V elsewhere pasted a stale
  -- charwise copy. The linewise flag still governs how *vim's* p re-inserts it.
  pcall(system.set_clipboard, text)
end

local function register_text()
  if M.active_reg and M.registers[M.active_reg] then
    local r = M.registers[M.active_reg]
    return r.text, r.linewise
  end
  if M.register.text ~= "" then return M.register.text, M.register.linewise end
  local ok, clip = pcall(system.get_clipboard)
  return (ok and clip or ""), false
end


-- ---- word motions (vim semantics, reusing translate primitives) ------------

-- Character class for word motions. `big` collapses to a two-way space/word
-- split (the WORD motions W/B/E); otherwise punctuation is its own class.
local function cls(doc, l, c, big)
  local ch = doc:get_char(l, c)
  if ch == "\n" or ch == "" then return "nl" end
  if ch:find("%s") then return "space" end
  if not big and config.non_word_chars:find(ch, nil, true) then return "punct" end
  return "word"
end

local function offset(doc, l, c, dir)
  local nl, nc = doc:position_offset(l, c, dir)
  if nl == l and nc == c then return nil end
  return nl, nc
end

local function at_end(doc, l, c)
  local el, ec = translate.end_of_doc(doc)
  return l >= el and c >= ec
end

-- start of the next word (w / W)
local function next_word(doc, line, col, big)
  local l, c = line, col
  local c0 = cls(doc, l, c, big)
  if c0 ~= "space" and c0 ~= "nl" then
    while not at_end(doc, l, c) do
      local nl, nc = offset(doc, l, c, 1)
      if not nl then break end
      l, c = nl, nc
      if cls(doc, l, c, big) ~= c0 then break end
    end
  else
    local nl, nc = offset(doc, l, c, 1)
    if nl then l, c = nl, nc end
  end
  while not at_end(doc, l, c) do
    local k = cls(doc, l, c, big)
    if k ~= "space" and k ~= "nl" then break end
    local nl, nc = offset(doc, l, c, 1)
    if not nl then break end
    l, c = nl, nc
  end
  return l, c
end

-- end of the next word (e / E), inclusive of the last character
local function next_word_end(doc, line, col, big)
  local l, c = line, col
  local nl, nc = offset(doc, l, c, 1)
  if not nl then return l, c end
  l, c = nl, nc
  while not at_end(doc, l, c) do
    local k = cls(doc, l, c, big)
    if k ~= "space" and k ~= "nl" then break end
    nl, nc = offset(doc, l, c, 1)
    if not nl then return l, c end
    l, c = nl, nc
  end
  local c0 = cls(doc, l, c, big)
  while true do
    nl, nc = offset(doc, l, c, 1)
    if not nl or cls(doc, nl, nc, big) ~= c0 then break end
    l, c = nl, nc
  end
  return l, c
end

-- start of the previous word (b / B)
local function prev_word(doc, line, col, big)
  local l, c = line, col
  local nl, nc = offset(doc, l, c, -1)
  if not nl then return l, c end
  l, c = nl, nc
  while l > 1 or c > 1 do
    local k = cls(doc, l, c, big)
    if k ~= "space" and k ~= "nl" then break end
    nl, nc = offset(doc, l, c, -1)
    if not nl then return l, c end
    l, c = nl, nc
  end
  local c0 = cls(doc, l, c, big)
  while true do
    nl, nc = offset(doc, l, c, -1)
    if not nl or cls(doc, nl, nc, big) ~= c0 then break end
    l, c = nl, nc
  end
  return l, c
end

local function first_nonblank(doc, line)
  return line, (doc.lines[line]:find("%S")) or 1
end


-- ---- f / F / t / T ---------------------------------------------------------

local function find_char_motion(dv, l, c, typ, ch, count)
  local s = dv.doc.lines[l]
  count = count or 1
  if typ == "f" or typ == "t" then
    local i = c
    for _ = 1, count do
      i = s:find(ch, i + 1, true)
      if not i then return nil end
    end
    if typ == "t" then i = i - 1; if i <= c then return nil end end
    return l, i, "inc"
  else
    local i = c
    for _ = 1, count do
      local prev, j = nil, 1
      while true do
        local k = s:find(ch, j, true)
        if not k or k >= i then break end
        prev, j = k, k + 1
      end
      if not prev then return nil end
      i = prev
    end
    if typ == "T" then i = i + 1; if i >= c then return nil end end
    return l, i, "exc"
  end
end

-- % -- jump to the bracket matching the first one at or after the caret.
local OPENERS = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local CLOSERS = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

local function match_bracket(doc, l, c)
  local s = doc.lines[l]
  local i, open, close, dir = c, nil, nil, nil
  while i <= #s do
    local ch = s:sub(i, i)
    if OPENERS[ch] then open, close, dir = ch, OPENERS[ch], 1; break end
    if CLOSERS[ch] then open, close, dir = ch, CLOSERS[ch], -1; break end
    i = i + 1
  end
  if not open then return nil end
  local depth, ll, cc = 0, l, i
  while true do
    local ch = doc:get_char(ll, cc)
    if ch == open then depth = depth + 1
    elseif ch == close then
      depth = depth - 1
      if depth == 0 then return ll, cc, "inc" end
    end
    local nl, nc = offset(doc, ll, cc, dir)
    if not nl then return nil end
    ll, cc = nl, nc
  end
end


-- ---- motion table ----------------------------------------------------------

-- Returns target line, col, and kind ("exc"|"inc"|"line"), or nil if the
-- motion cannot move. `count` is already the effective repeat count.
function M.motion(dv, name, count, arg, l, c, hadcount)
  local doc = dv.doc
  local function repeat_fn(fn)
    local nl, nc = l, c
    for _ = 1, count do nl, nc = fn(doc, nl, nc, dv) end
    return nl, nc
  end
  local function repeat_word(fn, big)
    local nl, nc = l, c
    for _ = 1, count do nl, nc = fn(doc, nl, nc, big) end
    return nl, nc
  end

  if name == "h" then local nl, nc = repeat_fn(translate.previous_char); return nl, nc, "exc"
  elseif name == "l" then local nl, nc = repeat_fn(translate.next_char); return nl, nc, "exc"
  elseif name == "j" then local nl, nc = repeat_fn(DocView.translate.next_line); return nl, nc, "line"
  elseif name == "k" then local nl, nc = repeat_fn(DocView.translate.previous_line); return nl, nc, "line"
  elseif name == "w" then local nl, nc = repeat_word(next_word, false); return nl, nc, "exc"
  elseif name == "W" then local nl, nc = repeat_word(next_word, true); return nl, nc, "exc"
  elseif name == "b" then local nl, nc = repeat_word(prev_word, false); return nl, nc, "exc"
  elseif name == "B" then local nl, nc = repeat_word(prev_word, true); return nl, nc, "exc"
  elseif name == "e" then local nl, nc = repeat_word(next_word_end, false); return nl, nc, "inc"
  elseif name == "E" then local nl, nc = repeat_word(next_word_end, true); return nl, nc, "inc"
  elseif name == "0" then return l, 1, "exc"
  elseif name == "^" then local nl, nc = first_nonblank(doc, l); return nl, nc, "exc"
  elseif name == "$" then return math.min(l + count - 1, #doc.lines), math.huge, "inc"
  elseif name == "{" then local nl, nc = repeat_fn(translate.previous_block_start); return nl, nc, "exc"
  elseif name == "}" then local nl, nc = repeat_fn(translate.next_block_end); return nl, nc, "exc"
  elseif name == "gg" then return (hadcount and math.min(count, #doc.lines) or 1), 1, "line"
  elseif name == "G" then return (hadcount and math.min(count, #doc.lines) or #doc.lines), 1, "line"
  elseif name == "%" then return match_bracket(doc, l, c)
  elseif name == "f" or name == "F" or name == "t" or name == "T" then
    return find_char_motion(dv, l, c, name, arg, count)
  elseif name == ";" then
    if not M.last_find then return nil end
    return find_char_motion(dv, l, c, M.last_find.type, M.last_find.char, count)
  elseif name == "," then
    if not M.last_find then return nil end
    local flip = { f = "F", F = "f", t = "T", T = "t" }
    return find_char_motion(dv, l, c, flip[M.last_find.type], M.last_find.char, count)
  end
  return nil
end

local MOTIONS = {
  h = true, l = true, j = true, k = true, w = true, W = true, b = true, B = true,
  e = true, E = true, ["0"] = true, ["^"] = true, ["$"] = true, ["{"] = true,
  ["}"] = true, G = true, [";"] = true, [","] = true, ["%"] = true,
  f = true, F = true, t = true, T = true,
}


-- ---- operators -------------------------------------------------------------

local function remove_lines(doc, minl, maxl)
  minl, maxl = math.max(1, minl), math.min(#doc.lines, maxl)
  if maxl < #doc.lines then
    doc:remove(minl, 1, maxl + 1, 1)
  else
    local sl = minl > 1 and minl - 1 or 1
    local sc = minl > 1 and math.huge or 1
    doc:remove(sl, sc, maxl, math.huge)
  end
end

local function linewise_text(doc, minl, maxl)
  local t = {}
  for i = math.max(1, minl), math.min(#doc.lines, maxl) do t[#t + 1] = doc.lines[i] end
  local s = table.concat(t)
  if s:sub(-1) ~= "\n" then s = s .. "\n" end -- last line has no trailing \n
  return s
end

function M.enter_insert(dv)
  local v = vstate(dv)
  v.mode = "insert"
  reset(v)
  v.mode = "insert"
  dv.blink_timer = 0
  mark_change()
end

function M.to_normal(dv)
  local v = vstate(dv)
  v.mode = "normal"
  v.block = nil
  reset(v)
  command.perform("doc:select-none")
end

local function linewise_op(dv, op, minl, maxl)
  local doc = dv.doc
  minl, maxl = math.max(1, minl), math.min(#doc.lines, maxl)
  local text = linewise_text(doc, minl, maxl)
  if op == "y" then
    M.set_register(text, true)
    doc:set_selection(minl, (doc.lines[minl]:find("%S")) or 1)
    return
  end
  M.set_register(text, true)
  mark_change()
  local indent = doc.lines[minl]:match("^[\t ]*") or ""
  remove_lines(doc, minl, maxl)
  if op == "d" then
    local nl = math.min(minl, #doc.lines)
    doc:set_selection(nl, (doc.lines[nl]:find("%S")) or 1)
  elseif op == "c" then
    local n = #doc.lines
    if minl > n then
      doc:insert(n, math.huge, "\n" .. indent)
      doc:set_selection(n + 1, #indent + 1)
    else
      doc:insert(minl, 1, indent .. "\n")
      doc:set_selection(minl, #indent + 1)
    end
    M.enter_insert(dv)
  end
end

local function indent_range(dv, op, l1, l2)
  mark_change()
  local doc = dv.doc
  local minl, maxl = math.min(l1, l2), math.max(l1, l2)
  doc:set_selection(minl, 1, maxl, math.huge)
  command.perform(op == ">" and "doc:indent" or "doc:unindent")
  doc:set_selection(minl, (doc.lines[minl]:find("%S")) or 1)
end

-- Apply `op` over the range from the caret (l1,c1) to the motion target
-- (l2,c2) classified by `kind`. Bridges vim's inclusive/linewise ranges onto
-- the engine's exclusive-end remove/get_text.
function M.do_operator(dv, op, l1, c1, l2, c2, kind, v)
  local doc = dv.doc
  if op == ">" or op == "<" then return indent_range(dv, op, l1, l2) end

  local a_first = (l1 < l2) or (l1 == l2 and c1 <= c2)
  local minl, minc, maxl, maxc
  if a_first then minl, minc, maxl, maxc = l1, c1, l2, c2
  else minl, minc, maxl, maxc = l2, c2, l1, c1 end

  if kind == "line" then return linewise_op(dv, op, minl, maxl) end

  -- Forward inclusive motion: extend the far end one char to cover the target.
  -- But NEVER cross the line boundary: `$` returns maxc = math.huge, and stepping
  -- one char past end-of-line lands on the next line, so d$/c$/D/C would delete
  -- the newline and join the lines. Clamp to the end of the line's content.
  if kind == "inc" and a_first then
    local nl, nc = translate.next_char(doc, maxl, maxc)
    if nl == maxl then
      maxl, maxc = nl, nc
    else
      local line = doc.lines[maxl] or ""
      maxc = #line - (line:sub(-1) == "\n" and 1 or 0) + 1
    end
  end

  local text = doc:get_text(minl, minc, maxl, maxc)
  if op == "y" then
    M.set_register(text, false)
    doc:set_selection(minl, minc)
  elseif op == "d" then
    mark_change()
    M.set_register(text, false)
    doc:remove(minl, minc, maxl, maxc)
    doc:set_selection(minl, minc)
  elseif op == "c" then
    M.set_register(text, false)
    doc:remove(minl, minc, maxl, maxc)
    doc:set_selection(minl, minc)
    M.enter_insert(dv)
  end
end

-- doubled operator (dd/cc/yy/>>/<<): whole lines from the caret.
local function linewise_operator(dv, op, count)
  local doc = dv.doc
  local l = doc:get_selection()
  local l2 = math.min(l + count - 1, #doc.lines)
  if op == ">" or op == "<" then indent_range(dv, op, l, l2)
  else linewise_op(dv, op, l, l2) end
end

-- Run an operator against a named motion (used by D, C, etc.).
local function op_motion(dv, op, name, count, arg)
  local doc = dv.doc
  local l, c = doc:get_selection()
  local tl, tc, kind = M.motion(dv, name, count, arg, l, c, true)
  if tl then M.do_operator(dv, op, l, c, tl, tc, kind, dv.vim) end
end


-- ---- text objects ----------------------------------------------------------

local PAIRS = {
  ["("] = { "(", ")" }, [")"] = { "(", ")" }, b = { "(", ")" },
  ["{"] = { "{", "}" }, ["}"] = { "{", "}" }, B = { "{", "}" },
  ["["] = { "[", "]" }, ["]"] = { "[", "]" },
}
local QUOTES = { ['"'] = true, ["'"] = true, ["`"] = true }

local function scan_back_open(doc, l, c, open, close)
  local ll, cc, depth = l, c, 0
  while true do
    local ch = doc:get_char(ll, cc)
    if ch == close and not (ll == l and cc == c) then depth = depth + 1
    elseif ch == open then
      if depth == 0 then return ll, cc end
      depth = depth - 1
    end
    local nl, nc = offset(doc, ll, cc, -1)
    if not nl then return nil end
    ll, cc = nl, nc
  end
end

local function scan_fwd_close(doc, l, c, open, close)
  local ll, cc, depth = l, c, 0
  while true do
    local ch = doc:get_char(ll, cc)
    if ch == open and not (ll == l and cc == c) then depth = depth + 1
    elseif ch == close then
      if depth == 0 then return ll, cc end
      depth = depth - 1
    end
    local nl, nc = offset(doc, ll, cc, 1)
    if not nl then return nil end
    ll, cc = nl, nc
  end
end

local function is_word_char(ch)
  return ch ~= "" and ch ~= "\n" and not config.non_word_chars:find(ch, nil, true)
end

-- Returns an INCLUSIVE range l1,c1,l2,c2 and a linewise flag for the text
-- object `obj` under (l,c). `ia` is "i" (inner) or "a" (around). nil if empty.
function M.text_object(dv, ia, obj, l, c)
  local doc = dv.doc
  local s = doc.lines[l]

  if obj == "w" or obj == "W" then
    local big = obj == "W"
    local member = big
      and function(ch) return ch ~= "" and ch ~= "\n" and not ch:find("%s") end
      or is_word_char
    local a, b = c, c
    if member(s:sub(c, c)) then
      while a > 1 and member(s:sub(a - 1, a - 1)) do a = a - 1 end
      while b < #s and member(s:sub(b + 1, b + 1)) do b = b + 1 end
    end
    if ia == "a" then
      local e = b
      while e < #s and s:sub(e + 1, e + 1):find("[ \t]") do e = e + 1 end
      if e > b then b = e
      else while a > 1 and s:sub(a - 1, a - 1):find("[ \t]") do a = a - 1 end end
    end
    return l, a, l, b, false

  elseif PAIRS[obj] then
    local open, close = PAIRS[obj][1], PAIRS[obj][2]
    local ol, oc = scan_back_open(doc, l, c, open, close)
    if not ol then return nil end
    local cl, cc = scan_fwd_close(doc, l, c, open, close)
    if not cl then return nil end
    if ia == "a" then return ol, oc, cl, cc, false end
    local il, ic = translate.next_char(doc, ol, oc)
    local jl, jc = translate.previous_char(doc, cl, cc)
    -- empty pair "()" -> nothing inside
    if il > jl or (il == jl and ic > jc) then return nil end
    return il, ic, jl, jc, false

  elseif QUOTES[obj] then
    local positions = {}
    for i = 1, #s do if s:sub(i, i) == obj then positions[#positions + 1] = i end end
    for i = 1, #positions - 1, 2 do
      local a, b = positions[i], positions[i + 1]
      if c <= b then
        if ia == "a" then return l, a, l, b, false end
        if b - 1 < a + 1 then return nil end
        return l, a + 1, l, b - 1, false
      end
    end
    return nil

  elseif obj == "p" then
    local function blank(i) return doc.lines[i]:find("^%s*$") ~= nil end
    local a, b = l, l
    local on_blank = blank(l)
    while a > 1 and blank(a - 1) == on_blank do a = a - 1 end
    while b < #doc.lines and blank(b + 1) == on_blank do b = b + 1 end
    if ia == "a" and not on_blank then
      while b < #doc.lines and blank(b + 1) do b = b + 1 end
    end
    return a, 1, b, 1, true
  end
  return nil
end


-- ---- normal-mode actions ---------------------------------------------------

local function delete_chars(dv, count, before)
  mark_change()
  local doc = dv.doc
  local l, c = doc:get_selection()
  local nl, nc = l, c
  if before then
    for _ = 1, count do
      if nc <= 1 then break end
      nl, nc = translate.previous_char(doc, nl, nc)
    end
    if nl ~= l or nc ~= c then
      M.set_register(doc:get_text(nl, nc, l, c), false)
      doc:remove(nl, nc, l, c)
      doc:set_selection(nl, nc)
    end
  else
    for _ = 1, count do
      local ch = doc:get_char(nl, nc)
      if ch == "\n" or ch == "" then break end
      nl, nc = translate.next_char(doc, nl, nc)
    end
    if nl ~= l or nc ~= c then
      M.set_register(doc:get_text(l, c, nl, nc), false)
      doc:remove(l, c, nl, nc)
      doc:set_selection(l, c)
    end
  end
end

local function replace_char(dv, ch, count)
  mark_change()
  local doc = dv.doc
  local l, c = doc:get_selection()
  local nl, nc = l, c
  for _ = 1, count do
    local cur = doc:get_char(nl, nc)
    if cur == "\n" or cur == "" then return end
    nl, nc = translate.next_char(doc, nl, nc)
  end
  doc:remove(l, c, nl, nc)
  doc:insert(l, c, string.rep(ch, count))
  local el, ec = doc:position_offset(l, c, count)
  el, ec = translate.previous_char(doc, el, ec)
  doc:set_selection(el, ec)
end

local function toggle_case(dv, count)
  mark_change()
  local doc = dv.doc
  for _ = 1, count do
    local l, c = doc:get_selection()
    local ch = doc:get_char(l, c)
    if ch == "\n" or ch == "" then break end
    local swapped = ch:match("%l") and ch:upper() or ch:match("%u") and ch:lower() or ch
    local nl, nc = translate.next_char(doc, l, c)
    doc:remove(l, c, nl, nc)
    doc:insert(l, c, swapped)
    doc:set_selection(translate.next_char(doc, l, c))
  end
end

function M.paste(dv, after, count)
  local doc = dv.doc
  local text, linewise = register_text()
  if text == "" then return end
  -- `3p` pastes the register three times (vim). Repeating the register text is
  -- the whole of it: for linewise text each copy already carries its newline, so
  -- three copies are three lines; charwise, three copies sit end to end.
  if count and count > 1 then text = text:rep(count) end
  mark_change()
  if linewise then
    local l = doc:get_selection()
    if after then
      if l < #doc.lines then
        doc:insert(l + 1, 1, text)
        doc:set_selection(l + 1, (doc.lines[l + 1]:find("%S")) or 1)
      else
        doc:insert(l, math.huge, "\n" .. text:gsub("\n$", ""))
        doc:set_selection(l + 1, (doc.lines[l + 1]:find("%S")) or 1)
      end
    else
      doc:insert(l, 1, text)
      doc:set_selection(l, (doc.lines[l]:find("%S")) or 1)
    end
  else
    local l, c = doc:get_selection()
    local il, ic = l, c
    if after then
      local ch = doc:get_char(l, c)
      if ch ~= "\n" and ch ~= "" then il, ic = translate.next_char(doc, l, c) end
    end
    doc:insert(il, ic, text)
    local el, ec = doc:position_offset(il, ic, #text)
    el, ec = translate.previous_char(doc, el, ec)
    doc:set_selection(el, ec)
  end
end

local function enter_insert_at(dv, where)
  local doc = dv.doc
  local l, c = doc:get_selection()
  if where == "a" then
    local ch = doc:get_char(l, c)
    if ch ~= "\n" and ch ~= "" then doc:set_selection(translate.next_char(doc, l, c)) end
  elseif where == "I" then
    doc:set_selection(first_nonblank(doc, l))
  elseif where == "A" then
    doc:set_selection(l, math.huge)
  elseif where == "o" then
    local indent = doc.lines[l]:match("^[\t ]*") or ""
    doc:insert(l, math.huge, "\n" .. indent)
    doc:set_selection(l + 1, #indent + 1)
  elseif where == "O" then
    local indent = doc.lines[l]:match("^[\t ]*") or ""
    doc:insert(l, 1, indent .. "\n")
    doc:set_selection(l, #indent + 1)
  end
  M.enter_insert(dv)
end

-- Single-key normal-mode commands that are not motions or operators.
local function do_action(dv, ch, v)
  local count = eff_count(v)
  if ch == "i" then M.enter_insert(dv)
  elseif ch == "a" then enter_insert_at(dv, "a")
  elseif ch == "I" then enter_insert_at(dv, "I")
  elseif ch == "A" then enter_insert_at(dv, "A")
  elseif ch == "o" then enter_insert_at(dv, "o")
  elseif ch == "O" then enter_insert_at(dv, "O")
  elseif ch == "x" then delete_chars(dv, count, false)
  elseif ch == "X" then delete_chars(dv, count, true)
  elseif ch == "D" then op_motion(dv, "d", "$", 1)
  elseif ch == "C" then op_motion(dv, "c", "$", 1)
  elseif ch == "Y" then linewise_operator(dv, "y", count)
  elseif ch == "s" then delete_chars(dv, count, false); M.enter_insert(dv)
  elseif ch == "S" then linewise_operator(dv, "c", count)
  elseif ch == "r" then v.await = "r"; return -- keep pending for the argument
  elseif ch == "~" then toggle_case(dv, count)
  elseif ch == "J" then mark_change(); for _ = 1, math.max(count - 1, 1) do command.perform("doc:join-lines") end
  elseif ch == "p" then M.paste(dv, true, count)
  elseif ch == "P" then M.paste(dv, false, count)
  elseif ch == "u" then for _ = 1, count do command.perform("doc:undo") end
  elseif ch == "v" then M.start_visual(dv, "visual")
  elseif ch == "V" then M.start_visual(dv, "vline")
  elseif ch == ":" then M.ex_prompt(dv)
  elseif ch == "/" then M.search_prompt(dv, false)
  elseif ch == "?" then M.search_prompt(dv, true)
  elseif ch == "n" then for _ = 1, count do M.search_next(dv, false) end
  elseif ch == "N" then for _ = 1, count do M.search_next(dv, true) end
  elseif ch == "*" then M.search_word(dv, false)
  elseif ch == "#" then M.search_word(dv, true)
  elseif ch == "." then M.dot_repeat(dv)
  end
  reset(v)
end

-- Open the ':' command line (falls back to nothing when there is no command
-- view, e.g. under a headless test harness).
function M.ex_prompt(dv)
  if not core.command_view then return end
  core.command_view:enter("", function(text) M.run_ex(dv, text) end)
end

function M.search_prompt(dv, reverse)
  if not core.command_view then return end
  core.command_view:enter(reverse and "?" or "/", function(text)
    if text and text ~= "" then M.do_search(dv, text, reverse) end
  end)
end


-- ---- visual mode -----------------------------------------------------------

function M.start_visual(dv, mode)
  local v = vstate(dv)
  v.mode = mode
  local l, c = dv.doc:get_selection()
  dv.doc:set_selection(l, c, l, c)
end

-- Returns true if the key was an action that concluded visual mode (or toggled
-- it); false lets the key fall through to a selection-extending motion.
local function visual_action(dv, ch)
  local doc = dv.doc
  local v = dv.vim
  local linewise = v.mode == "vline"

  if ch == "v" then
    if linewise then v.mode = "visual" else M.to_normal(dv) end
    return true
  elseif ch == "V" then
    if not linewise then v.mode = "vline" else M.to_normal(dv) end
    return true
  elseif ch == "o" then
    local al, ac, bl, bc = doc:get_selection()
    doc:set_selection(bl, bc, al, ac)
    return true
  end

  local opmap = { d = "d", x = "d", c = "c", s = "c", y = "y", [">"] = ">", ["<"] = "<" }
  local op = opmap[ch]
  if op then
    local l1, c1, l2, c2 = doc:get_selection(true)
    M.do_operator(dv, op, l1, c1, l2, c2, linewise and "line" or "inc", v)
    if op ~= "c" then M.to_normal(dv) else reset(v) end
    return true
  end
  if ch == "~" then
    local l1, c1, l2, c2 = doc:get_selection(true)
    doc:set_selection(l1, c1)
    local n = 0
    -- toggle across the (inclusive) selection on the same line span
    local ll, cc = l1, c1
    while (ll < l2) or (ll == l2 and cc <= c2) do
      local cur = doc:get_char(ll, cc)
      if cur ~= "\n" and cur ~= "" then
        local sw = cur:match("%l") and cur:upper() or cur:match("%u") and cur:lower() or cur
        local nl, nc = translate.next_char(doc, ll, cc)
        doc:remove(ll, cc, nl, nc); doc:insert(ll, cc, sw)
      end
      local nl, nc = translate.next_char(doc, ll, cc)
      if nl == ll and nc == cc then break end
      ll, cc = nl, nc
      n = n + 1
      if n > 100000 then break end
    end
    M.to_normal(dv)
    return true
  end
  if ch == "p" then
    local l1, c1, l2, c2 = doc:get_selection(true)
    local ml, mc = translate.next_char(doc, l2, c2)
    doc:remove(l1, c1, ml, mc)
    doc:set_selection(l1, c1)
    M.paste(dv, false)
    M.to_normal(dv)
    return true
  end
  return false
end


-- ---- visual-block mode (Ctrl-V) --------------------------------------------

-- Column range of a line, excluding the trailing newline.
local function line_last_col(doc, i)
  local s = doc.lines[i]
  return #s - (s:sub(-1) == "\n" and 1 or 0)
end

local function block_bounds(v)
  local b = v.block
  return math.min(b.al, b.cl), math.max(b.al, b.cl),
         math.min(b.ac, b.cc), math.max(b.ac, b.cc)
end
M.block_bounds = block_bounds

function M.start_vblock(dv)
  local v = vstate(dv)
  local l, c = dv.doc:get_selection()
  v.mode = "vblock"
  v.block = { al = l, ac = c, cl = l, cc = c }
  dv.doc:set_selection(l, c)
end

-- Enter insert at `col` on the top line of a block; the typed text is
-- replicated to lines minl+1..maxl on escape (block I / A / c).
function M.begin_block_insert(dv, minl, maxl, col)
  local v = vstate(dv)
  dv.doc:set_selection(minl, col)
  M.enter_insert(dv)
  v.binsert = { minl = minl, maxl = maxl, col = col, text = "" }
end

local function block_operate(dv, op)
  local v = dv.vim
  local doc = dv.doc
  local minl, maxl, minc, maxc = block_bounds(v)

  if op == "y" then
    local parts = {}
    for i = minl, maxl do
      local last = line_last_col(doc, i)
      local a, b = math.min(minc, last + 1), math.min(maxc, last)
      parts[#parts + 1] = (b >= a) and doc.lines[i]:sub(a, b) or ""
    end
    M.set_register(table.concat(parts, "\n"), false)
    doc:set_selection(minl, minc)
    M.to_normal(dv)
    return
  end

  mark_change()
  for i = maxl, minl, -1 do
    local last = line_last_col(doc, i)
    local a, b = math.min(minc, last + 1), math.min(maxc + 1, last + 1)
    if b > a then doc:remove(i, a, i, b) end
  end
  doc:set_selection(minl, minc)
  if op == "c" then
    v.mode = "normal"; v.block = nil
    M.begin_block_insert(dv, minl, maxl, minc)
  else
    M.to_normal(dv)
  end
end

-- Handle a key while in visual-block mode. Returns true if consumed; false
-- lets the key fall through to a motion that moves the block's caret corner.
function M.block_action(dv, ch)
  local v = dv.vim
  if ch == "v" or ch == "V" then M.to_normal(dv); return true end
  if ch == "o" then
    local b = v.block
    b.al, b.ac, b.cl, b.cc = b.cl, b.cc, b.al, b.ac
    dv.doc:set_selection(b.cl, b.cc)
    return true
  end
  if ch == "d" or ch == "x" then block_operate(dv, "d"); return true end
  if ch == "y" then block_operate(dv, "y"); return true end
  if ch == "c" or ch == "s" then block_operate(dv, "c"); return true end
  if ch == "I" then
    local minl, maxl, minc = block_bounds(v)
    v.mode = "normal"; v.block = nil
    M.begin_block_insert(dv, minl, maxl, minc)
    return true
  end
  if ch == "A" then
    local minl, maxl, _, maxc = block_bounds(v)
    v.mode = "normal"; v.block = nil
    M.begin_block_insert(dv, minl, maxl, maxc + 1)
    return true
  end
  return false
end


-- ---- multi-cursor (additive; Doc stays single-selection) -------------------
--
-- Extra carets live in dv.vim.cursors as {line, col}. A buffer-changing command
-- is typed once at the primary caret; on completion it is REPLAYED at every
-- other cursor via the dot-repeat machinery (bottom-to-top so edits never
-- invalidate a not-yet-visited cursor's position). This reuses one code path
-- for "repeat the last change" and "apply the change at N cursors".

M.mc_snapshot = nil   -- cursor positions captured when a change begins
M.mc_active = nil     -- the primary position the change is performed at

-- Add the next occurrence of the word under the caret as a new cursor.
function M.add_cursor_next(dv)
  local v = vstate(dv)
  local doc = dv.doc
  if not v.cursors or #v.cursors == 0 then
    -- seed with the word under the caret
    local l, c = doc:get_selection()
    local s = doc.lines[l]
    local function isw(ch)
      return ch ~= "" and ch ~= "\n" and not config.non_word_chars:find(ch, nil, true)
    end
    local a, b = c, c
    while a > 1 and isw(s:sub(a - 1, a - 1)) do a = a - 1 end
    while b <= #s and isw(s:sub(b, b)) do b = b + 1 end
    v.mc_word = s:sub(a, b - 1)
    if v.mc_word == "" then return end
    v.cursors = { { l, a } }
    doc:set_selection(l, a)
  end
  local last = v.cursors[#v.cursors]
  local nl, nc = search.find(doc, last[1], last[2] + 1, v.mc_word, { wrap = true })
  if not nl then return end
  for _, cur in ipairs(v.cursors) do
    if cur[1] == nl and cur[2] == nc then return end -- full circle
  end
  v.cursors[#v.cursors + 1] = { nl, nc }
  doc:set_selection(nl, nc)
end

function M.clear_cursors(dv)
  local v = rawget(dv, "vim")
  if v then v.cursors, v.mc_word = nil, nil end
end

-- Replay M.last_change_keys once at the current primary caret.
local function replay_change(dv)
  local seq = M.last_change_keys
  if not seq then return end
  for i = 1, #seq do
    local ch = seq:sub(i, i)
    if ch == "\27" then M.escape(dv)
    elseif dv.vim and dv.vim.mode == "insert" then dv.doc:text_input(ch)
    else M.on_char(dv, ch) end
  end
end

-- After a change committed at M.mc_active, apply it at the other cursors.
local function fan_to_cursors(dv)
  local snap = M.mc_snapshot
  M.mc_snapshot = nil
  if not snap or not M.mc_active then return end
  local doc = dv.doc
  local others = {}
  for _, cur in ipairs(snap) do
    if not (cur[1] == M.mc_active[1] and cur[2] == M.mc_active[2]) then
      others[#others + 1] = cur
    end
  end
  table.sort(others, function(a, b)
    if a[1] ~= b[1] then return a[1] > b[1] end
    return a[2] > b[2]
  end)
  local was_replaying = M.replaying
  M.replaying = true
  local updated = {}
  for _, cur in ipairs(others) do
    doc:set_selection(cur[1], math.min(cur[2], line_last_col(doc, cur[1]) + 1))
    replay_change(dv)
    local nl, nc = doc:get_selection()
    updated[#updated + 1] = { nl, nc }
  end
  M.replaying = was_replaying
  -- keep the cursor set for further edits
  updated[#updated + 1] = { doc:get_selection() }
  dv.vim.cursors = updated
end
M.fan_to_cursors = fan_to_cursors


-- ---- the grammar dispatcher ------------------------------------------------

-- Apply the pending operator / visual selection to an explicit text-object
-- range (inclusive endpoints), computed by M.text_object.
local function apply_object(dv, v, ia, obj)
  local l, c = dv.doc:get_selection()
  local l1, c1, l2, c2, linewise = M.text_object(dv, ia, obj, l, c)
  if not l1 then reset(v); return end
  M.active_reg = v.reg
  if v.op then
    M.do_operator(dv, v.op, l1, c1, l2, c2, linewise and "line" or "inc", v)
  elseif v.mode == "visual" or v.mode == "vline" then
    dv.doc:set_selection(l2, c2, l1, c1)
  end
  reset(v)
end

-- The state machine proper. Mutates the doc / vim state; returns nothing.
local function dispatch(dv, ch, v)
  M.active_reg = v.reg

  -- awaiting a single-character argument (r, f/F/t/T, register, text object)
  if v.await then
    local a = v.await
    if a == "reg" then
      v.reg = ch; v.await = nil; return
    elseif a == "object" then
      apply_object(dv, v, v.textobj, ch); return
    elseif a == "r" then
      replace_char(dv, ch, eff_count(v)); reset(v); return
    elseif a == "f" or a == "F" or a == "t" or a == "T" then
      M.last_find = { type = a, char = ch }
      local count = eff_count(v)
      local l, c = dv.doc:get_selection()
      local tl, tc, kind = find_char_motion(dv, l, c, a, ch, count)
      v.await = nil
      if tl then
        if v.op then M.do_operator(dv, v.op, l, c, tl, tc, kind, v)
        elseif v.mode == "visual" or v.mode == "vline" then
          local _, _, bl, bc = dv.doc:get_selection()
          dv.doc:set_selection(tl, tc, bl, bc)
        else dv.doc:set_selection(tl, tc) end
      end
      reset(v); return
    end
    reset(v); return
  end

  -- second key of a g-command
  if v.gpend then
    v.gpend = false
    if ch == "g" then return M.dispatch_motion(dv, "gg") end
    reset(v); return
  end

  if ch == " " then ch = "l" end -- space is "move right" in normal mode

  -- register select: "a ... use register a for the next yank/delete/paste
  if ch == '"' then v.await = "reg"; return end

  -- visual mode: an action ends the mode; anything else extends the selection
  if v.mode == "vblock" then
    if M.block_action(dv, ch) then return end
  elseif v.mode == "visual" or v.mode == "vline" then
    if visual_action(dv, ch) then return end
  end

  -- counts (but a leading "0" is the start-of-line motion)
  if ch:match("%d") then
    local buffering = v.op and v.opcount ~= "" or (not v.op and v.count ~= "")
    if not (ch == "0" and not buffering) then
      if v.op then v.opcount = v.opcount .. ch else v.count = v.count .. ch end
      return
    end
  end

  -- operators
  if ch == "d" or ch == "c" or ch == "y" or ch == ">" or ch == "<" then
    if v.op == ch then linewise_operator(dv, ch, eff_count(v)); reset(v); return end
    if v.op then reset(v); return end
    v.op = ch; return
  end

  -- text object (i/a) after an operator or in visual mode
  if (v.op or v.mode == "visual" or v.mode == "vline") and (ch == "i" or ch == "a") then
    v.await = "object"; v.textobj = ch; return
  end

  if ch == "g" then v.gpend = true; return end

  -- motions
  if MOTIONS[ch] then
    if ch == "f" or ch == "F" or ch == "t" or ch == "T" then v.await = ch; return end
    return M.dispatch_motion(dv, ch)
  end

  -- an operator was pending but the key isn't a motion: cancel it
  if v.op then reset(v); return end

  do_action(dv, ch, v)
end

-- Whether the machine is at rest in normal mode (used to bound dot-repeat
-- recording: a change is one command from idle back to idle).
local function idle_normal(v)
  return v.mode == "normal" and not v.op and not v.await and not v.gpend
     and v.count == "" and not v.reg
end

-- Fed one input character at a time from DocView:on_text_input while in a
-- non-insert mode. Wraps `dispatch` with dot-repeat keystroke recording.
function M.on_char(dv, ch)
  local v = vstate(dv)
  if not v then return end

  if not M.replaying then
    if not M.rec_active and idle_normal(v) and ch ~= "." then
      M.rec_active, M.rec, M.rec_is_change = true, "", false
      -- If extra cursors are live, snapshot them so the change can be fanned
      -- out once it completes (the change itself runs at the primary caret).
      if v.cursors and #v.cursors > 1 then
        M.mc_snapshot = v.cursors
        M.mc_active = { dv.doc:get_selection() }
      else
        M.mc_snapshot = nil
      end
    end
    if M.rec_active then M.rec = M.rec .. ch end
  end

  dispatch(dv, ch, v)

  -- A command that returned to idle either committed a change worth repeating,
  -- or was a pure motion whose recording we discard. Insert-entering commands
  -- are not idle yet; they commit from M.leave_insert on escape.
  if not M.replaying and M.rec_active and idle_normal(v) then
    if M.rec_is_change then
      M.last_change_keys = M.rec
      M.rec_active = false
      if M.mc_snapshot then fan_to_cursors(dv) end
    else
      M.rec_active = false
      M.mc_snapshot = nil
    end
  end
end

-- Replay the last change's keystrokes. Routes each key exactly as the real
-- input path would: escape leaves insert, typed text lands in insert, and
-- normal-mode keys drive the grammar.
function M.dot_repeat(dv)
  local seq = M.last_change_keys
  if not seq then return end
  M.replaying = true
  for i = 1, #seq do
    local ch = seq:sub(i, i)
    if ch == "\27" then M.escape(dv)
    elseif dv.vim and dv.vim.mode == "insert" then dv.doc:text_input(ch)
    else M.on_char(dv, ch) end
  end
  M.replaying = false
end

-- Resolve a motion by name and either apply the pending operator over it, or
-- move / extend the selection.
function M.dispatch_motion(dv, name)
  local v = vstate(dv)
  local doc = dv.doc
  -- vim's cw quirk: cw / cW on a non-blank acts like ce / cE. It changes to the
  -- END of the word rather than the start of the next one, so it does not also
  -- swallow the whitespace after the word (which plain `w` as an operator target
  -- would). Only when sitting on a non-blank -- on whitespace, cw keeps meaning w.
  if v.op == "c" and (name == "w" or name == "W") then
    local sl, sc = doc:get_selection()
    local ch = doc:get_char(sl, sc)
    if ch and ch:match("%S") then name = (name == "w") and "e" or "E" end
  end
  local count = eff_count(v)
  local l, c = doc:get_selection()
  local tl, tc, kind = M.motion(dv, name, count, nil, l, c, had_count(v))
  if not tl then reset(v); return end
  if v.op then
    M.do_operator(dv, v.op, l, c, tl, tc, kind, v)
  elseif v.mode == "vblock" then
    v.block.cl, v.block.cc = tl, tc
    doc:set_selection(tl, tc)
  elseif v.mode == "visual" or v.mode == "vline" then
    local _, _, bl, bc = doc:get_selection()
    doc:set_selection(tl, tc, bl, bc)
  else
    doc:set_selection(tl, tc)
  end
  reset(v)
end


-- ---- leaving insert / escape -----------------------------------------------

function M.leave_insert(dv)
  local v = vstate(dv)
  v.mode = "normal"
  local binsert = v.binsert
  v.binsert = nil
  reset(v)
  local doc = dv.doc
  -- Block insert (Ctrl-V I/A, or block c): replicate the typed text down the
  -- block's remaining lines at the same column.
  if binsert and binsert.text ~= "" then
    for i = binsert.minl + 1, binsert.maxl do
      if binsert.col <= line_last_col(doc, i) + 1 then
        doc:insert(i, binsert.col, binsert.text)
      end
    end
  end
  local l, c = doc:get_selection()
  if c > 1 then doc:set_selection(translate.previous_char(doc, l, c)) end
  -- Finalise a dot-repeat recording: the insert session ended, so the recorded
  -- entry + typed text + this escape is the repeatable change.
  if not M.replaying and M.rec_active then
    M.rec = M.rec .. "\27"
    M.last_change_keys = M.rec
    M.rec_active = false
    if M.mc_snapshot then fan_to_cursors(dv) end
  end
end

function M.escape(dv)
  local v = vstate(dv)
  if v.mode == "insert" then
    M.leave_insert(dv)
  elseif v.mode == "visual" or v.mode == "vline" or v.mode == "vblock" then
    M.to_normal(dv)
  else
    reset(v)
    if v.cursors then M.clear_cursors(dv) end
    if dv.doc:has_selection() then command.perform("doc:select-none") end
  end
end


-- ---- ex commands (:) -------------------------------------------------------

-- Pure parser: split an ex command line into a range, a command word, a bang,
-- an argument, and (for :s) the parsed substitution. Takes no editor state, so
-- it is directly unit-testable; addresses are resolved against the doc later.
--
-- Returns { range, cmd, bang, arg, sub } where:
--   range = nil | { whole = true } | { a = <addr> } | { a = <addr>, b = <addr> }
--   addr  = a line number, "." (current), or "$" (last)
--   sub   = { pattern, replacement, flags } for :s, else nil
function M.parse_ex(str)
  str = str:gsub("^:", ""):gsub("^%s+", "")
  local pos = 1
  local function peek() return str:sub(pos, pos) end
  local function read_addr()
    local c = peek()
    if c == "." then pos = pos + 1; return "." end
    if c == "$" then pos = pos + 1; return "$" end
    local num = str:match("^%d+", pos)
    if num then pos = pos + #num; return tonumber(num) end
    return nil
  end

  local range
  if peek() == "%" then
    pos = pos + 1
    range = { whole = true }
  else
    local a = read_addr()
    if a ~= nil then
      if peek() == "," or peek() == ";" then
        pos = pos + 1
        range = { a = a, b = read_addr() or "." }
      else
        range = { a = a }
      end
    end
  end

  local rest = str:sub(pos):gsub("^%s+", "")
  local cmd = rest:match("^%a+")
  if not cmd then
    -- a bare address (":10", ":%") with no command means "go there".
    return { range = range, cmd = range and "goto" or "" }
  end

  local after = rest:sub(#cmd + 1)
  local bang = false
  if after:sub(1, 1) == "!" then bang = true; after = after:sub(2) end

  local sub
  if cmd == "s" or cmd == "substitute" then
    local delim = after:sub(1, 1)
    if delim ~= "" and not delim:match("[%w%s]") then
      local rec = {}
      for part in (after:sub(2) .. delim):gmatch("(.-)" .. "%" .. delim) do
        rec[#rec + 1] = part
      end
      sub = { pattern = rec[1] or "", replacement = rec[2] or "",
              flags = (rec[3] or ""):gsub("%s+$", "") }
    end
  end

  return { range = range, cmd = cmd, bang = bang,
           arg = after:gsub("^%s+", ""), sub = sub }
end

-- Substitute `pattern`->`replacement` (Lua patterns) across lines l1..l2.
local function ex_substitute(dv, l1, l2, sub)
  local doc = dv.doc
  local all = sub.flags:find("g") ~= nil
  local last
  for i = l1, l2 do
    local ln = doc.lines[i]
    local has_nl = ln:sub(-1) == "\n"
    local bodytext = has_nl and ln:sub(1, -2) or ln
    local ok, newbody = pcall(function()
      return all and (bodytext:gsub(sub.pattern, sub.replacement))
                  or (bodytext:gsub(sub.pattern, sub.replacement, 1))
    end)
    if not ok then core.error("bad pattern: %s", sub.pattern); return end
    if newbody ~= bodytext then
      doc:remove(i, 1, i, #bodytext + 1)
      if newbody ~= "" then doc:insert(i, 1, newbody) end
      last = i
    end
  end
  if last then doc:set_selection(last, 1) end
end

-- Resolve `arg` (a trailing address for :m / :t) to a line number.
local function resolve_arg_addr(doc, cur, arg)
  arg = arg:gsub("%s+", "")
  if arg == "." then return cur end
  if arg == "$" then return #doc.lines end
  if arg == "0" then return 0 end
  local n = tonumber(arg)
  return n
end

function M.run_ex(dv, str)
  local p = M.parse_ex(str)
  local doc = dv.doc
  local cur = doc:get_selection()

  local function resolve(addr)
    if addr == "." then return cur end
    if addr == "$" then return #doc.lines end
    if type(addr) == "number" then return addr end
    return cur
  end

  local l1, l2
  if p.range then
    if p.range.whole then l1, l2 = 1, #doc.lines
    elseif p.range.b ~= nil then l1, l2 = resolve(p.range.a), resolve(p.range.b)
    else l1 = resolve(p.range.a); l2 = l1 end
    if l1 > l2 then l1, l2 = l2, l1 end
    l1 = math.max(1, math.min(l1, #doc.lines))
    l2 = math.max(1, math.min(l2, #doc.lines))
  end

  local cmd = p.cmd
  if cmd == "" then
    return
  elseif cmd == "goto" then
    doc:set_selection(l2, 1); pcall(dv.scroll_to_line, dv, l2, true)
  elseif cmd == "w" or cmd == "write" then
    command.perform("doc:save")
  elseif cmd == "q" or cmd == "quit" then
    command.perform("root:close")
  elseif cmd == "wq" or cmd == "x" or cmd == "xit" then
    command.perform("doc:save"); command.perform("root:close")
  elseif cmd == "d" or cmd == "delete" then
    l1, l2 = l1 or cur, l2 or cur
    M.set_register(linewise_text(doc, l1, l2), true)
    remove_lines(doc, l1, l2)
    local nl = math.min(l1, #doc.lines)
    doc:set_selection(nl, 1)
  elseif cmd == "y" or cmd == "yank" then
    l1, l2 = l1 or cur, l2 or cur
    M.set_register(linewise_text(doc, l1, l2), true)
  elseif cmd == "s" or cmd == "substitute" then
    if p.sub then ex_substitute(dv, l1 or cur, l2 or cur, p.sub)
    else core.error("bad :substitute") end
  elseif cmd == "m" or cmd == "move" or cmd == "t" or cmd == "co" or cmd == "copy" then
    l1, l2 = l1 or cur, l2 or cur
    local dest = resolve_arg_addr(doc, cur, p.arg)
    if not dest then core.error("bad destination"); return end
    local text = linewise_text(doc, l1, l2)
    local moving = (cmd == "m" or cmd == "move")
    if moving then remove_lines(doc, l1, l2); if dest > l2 then dest = dest - (l2 - l1 + 1) end end
    if dest <= 0 then doc:insert(1, 1, text)
    else doc:insert(dest, math.huge, "\n" .. text:gsub("\n$", "")) end
  elseif cmd == "noh" or cmd == "nohlsearch" then
    M.search_text = nil
  elseif cmd == "set" then
    if p.arg == "vim" then M.enabled = true; config.vim_mode = true
    elseif p.arg == "novim" then M.enabled = false; config.vim_mode = false end
  else
    core.error("not an editor command: %s", cmd)
  end
end


-- ---- search (/ ? n N * #) --------------------------------------------------

M.search_text = nil
M.search_reverse = false

-- Backward literal search for `text` starting before (line, col), wrapping.
local function rfind(doc, line, col, text)
  local function last_before(s, upto)
    local found, init = nil, 1
    while true do
      local a = s:find(text, init, true)
      if not a or (upto and a >= upto) then break end
      found, init = a, a + 1
    end
    return found
  end
  local a = last_before(doc.lines[line], col)
  if a then return line, a end
  for i = line - 1, 1, -1 do
    local aa = last_before(doc.lines[i], nil)
    if aa then return i, aa end
  end
  for i = #doc.lines, line, -1 do
    local aa = last_before(doc.lines[i], nil)
    if aa then return i, aa end
  end
  return nil
end

function M.search_next(dv, opposite)
  if not M.search_text or M.search_text == "" then return end
  local doc = dv.doc
  local rev = M.search_reverse
  if opposite then rev = not rev end
  local l, c = doc:get_selection()
  local nl, nc
  if rev then
    nl, nc = rfind(doc, l, c, M.search_text)
  else
    nl, nc = search.find(doc, l, c + 1, M.search_text, { wrap = true })
  end
  if nl then doc:set_selection(nl, nc); pcall(dv.scroll_to_line, dv, nl, true) end
end

function M.do_search(dv, text, reverse)
  M.search_text = text
  M.search_reverse = reverse and true or false
  M.search_next(dv, false)
end

-- Search for the word under the caret (* forward, # backward).
function M.search_word(dv, reverse)
  local doc = dv.doc
  local l, c = doc:get_selection()
  local s = doc.lines[l]
  local function is_word(ch)
    return ch ~= "" and ch ~= "\n" and not config.non_word_chars:find(ch, nil, true)
  end
  local a, b = c, c
  while a > 1 and is_word(s:sub(a - 1, a - 1)) do a = a - 1 end
  while b <= #s and is_word(s:sub(b, b)) do b = b + 1 end
  local word = s:sub(a, b - 1)
  if word == "" then return end
  M.search_text, M.search_reverse = word, reverse and true or false
  doc:set_selection(l, a)
  M.search_next(dv, false)
end


-- ---- integration hooks (caret shape + status chip) -------------------------

-- Consumed by docview.lua: "block" in normal/visual, "bar" in insert, nil when
-- vim is off (the editor draws its usual blinking bar).
function core.vim_caret(dv)
  if not M.enabled then return nil end
  if getmetatable(dv) ~= DocView then return nil end
  local v = vstate(dv)
  if not v then return nil end
  return v.mode == "insert" and "bar" or "block"
end

local MODE_LABEL = { normal = "NORMAL", insert = "INSERT", visual = "VISUAL",
                     vline = "V-LINE", vblock = "V-BLOCK" }

-- Consumed by statusview.lua: a small item list spliced onto the left group.
function core.vim_status(dv)
  if not M.enabled then return nil end
  if getmetatable(dv) ~= DocView then return nil end
  local v = vstate(dv)
  if not v then return nil end
  local pend = (v.count or "") .. (v.op or "") .. (v.opcount or "")
  if v.await then pend = pend .. v.await end
  local items = { style.accent, style.font, MODE_LABEL[v.mode] or v.mode:upper() }
  if v.cursors and #v.cursors > 1 then
    items[#items + 1] = style.dim
    items[#items + 1] = " " .. #v.cursors .. " cursors"
  end
  if pend ~= "" then items[#items + 1] = style.dim; items[#items + 1] = " " .. pend end
  return items
end

-- Consumed by docview.lua draw_line_body: draw the block-selection column and
-- any extra multi-cursor carets that fall on line `idx`.
function core.vim_overlay(dv, idx, x, y)
  if not M.enabled then return end
  if getmetatable(dv) ~= DocView then return end
  local v = rawget(dv, "vim")
  if not v then return end
  local lh = dv:get_line_height()
  if v.mode == "vblock" and v.block then
    local minl, maxl, minc, maxc = M.block_bounds(v)
    if idx >= minl and idx <= maxl then
      local x1 = x + dv:get_col_x_offset(idx, minc)
      local x2 = x + dv:get_col_x_offset(idx, maxc + 1)
      renderer.draw_rect(x1, y, math.max(x2 - x1, 2), lh, style.selection)
    end
  end
  if v.cursors then
    for _, cur in ipairs(v.cursors) do
      if cur[1] == idx then
        local x1 = x + dv:get_col_x_offset(idx, cur[2])
        renderer.draw_rect(x1, y, style.caret_width * 2, lh, style.caret)
      end
    end
  end
end


-- ---- input plumbing: wrap DocView:on_text_input ----------------------------

local orig_on_text_input = DocView.on_text_input
function DocView:on_text_input(text)
  if M.enabled then
    local v = vstate(self)
    if v and v.mode ~= "insert" then
      M.on_char(self, text)
      return
    end
    -- typing in insert mode: fold it into any active dot-repeat recording...
    if v and M.rec_active and not M.replaying then
      M.rec = M.rec .. text
      M.rec_is_change = true
    end
    -- ...and into a block-insert accumulator, to replicate on escape.
    if v and v.binsert and not M.replaying then
      v.binsert.text = v.binsert.text .. text
    end
  end
  orig_on_text_input(self, text)
end


-- ---- commands + keymap -----------------------------------------------------

-- vim is active on a real editor DocView (any mode).
local function editing()
  if not M.enabled then return false end
  local av = core.active_view
  if getmetatable(av) ~= DocView then return false end
  return vstate(av) ~= nil
end

-- ...and specifically not in insert mode -- so the destructive doc bindings
-- fall through to their defaults while typing.
local function editing_cmd()
  return editing() and core.active_view.vim.mode ~= "insert"
end

command.add(editing, {
  ["vim:normal-mode"] = function() M.escape(core.active_view) end,
})

command.add(editing_cmd, {
  ["vim:backspace"] = function()
    local doc = core.active_view.doc
    doc:move_to(translate.previous_char)
  end,
  ["vim:delete"] = function() delete_chars(core.active_view, 1, false) end,
  ["vim:return"] = function()
    local doc = core.active_view.doc
    local l = doc:get_selection()
    local nl = math.min(l + 1, #doc.lines)
    doc:set_selection(nl, (doc.lines[nl]:find("%S")) or 1)
  end,
  ["vim:tab"] = function() end,
  ["vim:shift-tab"] = function() end,
  ["vim:redo"] = function() command.perform("doc:redo") end,
  ["vim:half-page-down"] = function()
    local dv = core.active_view; local doc = dv.doc
    local min, max = dv:get_visible_line_range()
    local half = math.max(1, math.floor((max - min) / 2))
    local l, c = doc:get_selection()
    doc:set_selection(math.min(l + half, #doc.lines), c)
  end,
  ["vim:half-page-up"] = function()
    local dv = core.active_view; local doc = dv.doc
    local min, max = dv:get_visible_line_range()
    local half = math.max(1, math.floor((max - min) / 2))
    local l, c = doc:get_selection()
    doc:set_selection(math.max(l - half, 1), c)
  end,
  ["vim:visual-block"] = function()
    local dv = core.active_view
    local v = vstate(dv)
    if v.mode == "vblock" then M.to_normal(dv) else M.start_vblock(dv) end
  end,
  ["vim:add-cursor-next-match"] = function() M.add_cursor_next(core.active_view) end,
  ["vim:clear-cursors"] = function() M.clear_cursors(core.active_view) end,
})

-- Toggle is always available (predicate is unconditional) so vim can be turned
-- on at runtime without a restart.
command.add(nil, {
  ["vim:toggle"] = function()
    M.enabled = not M.enabled
    config.vim_mode = M.enabled
    if M.enabled and getmetatable(core.active_view) == DocView then
      vstate(core.active_view).mode = "normal"
    end
    core.log("vim mode %s", M.enabled and "enabled" or "disabled")
  end,
})

-- Prepend the modal bindings for keys that would otherwise run a destructive or
-- unwanted doc command in normal mode. Because keymap.add prepends and
-- command.perform skips a command whose predicate fails, each of these falls
-- through to its original binding when vim is off or we're in insert mode.
keymap.add {
  ["escape"] = "vim:normal-mode",
  ["backspace"] = "vim:backspace",
  ["shift+backspace"] = "vim:backspace",
  ["delete"] = "vim:delete",
  ["shift+delete"] = "vim:delete",
  ["return"] = "vim:return",
  ["keypad enter"] = "vim:return",
  ["tab"] = "vim:tab",
  ["shift+tab"] = "vim:shift-tab",
  ["ctrl+r"] = "vim:redo",
  ["ctrl+d"] = "vim:half-page-down",
  ["ctrl+u"] = "vim:half-page-up",
  ["ctrl+v"] = "vim:visual-block",
  ["ctrl+n"] = "vim:add-cursor-next-match",
}


return M
