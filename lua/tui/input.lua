-- tui/input.lua -- multiline composer for the full-screen cTUI (Contract C).
-- Events are tc.poll / tests: ev.key, ev.char, shift/alt/ctrl, type="paste".
-- Pure state. Lua 5.5: never table.insert(t, 1, x) on an empty table.
local M = {}
local Input = {}
Input.__index = Input

local PROMPT = "> "
local HISTORY_MAX, VISUAL_MAX = 200, 8
local STYLE_FG = {
  ["bog-cmd"]  = "#7fb77e",
  ["bog-bad"]  = "#f77483",
  ["bog-file"] = "#93ddfa",
}
local MENU_FG, MENU_BG, DIM = "e1e1e6", "252529", "525257"

local function ulen(s)
  return (utf8 and utf8.len(s)) or #s
end
local function byteat(s, i)
  if i <= 0 then return 1 end
  if not utf8 then return math.min(i, #s) + 1 end
  return utf8.offset(s, i + 1) or (#s + 1)
end
local function utf8_trim(s)
  if not utf8 then return s end
  while #s > 0 and not utf8.len(s) do s = s:sub(1, #s - 1) end
  return s
end
local function cp_at(s, i)
  if i < 0 or i >= ulen(s) then return 0 end
  local a, b = byteat(s, i), byteat(s, i + 1)
  local ok, cp = pcall(utf8.codepoint, s:sub(a, b - 1))
  return (ok and cp) or 0
end
local function is_word(cp)
  return (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90)
      or (cp >= 97 and cp <= 122) or cp == 95
end
local function vis_w(s)
  if sys and sys.width then return sys.width(s) end
  return ulen(s)
end
local function safe(fn, arg)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, arg)
  return ok and v or nil
end
local function item_text(it)
  if type(it) == "table" then return it.text or "" end
  return tostring(it or "")
end

function M.new(opts)
  opts = opts or {}
  local hist = {}
  if opts.history then
    for _, h in ipairs(opts.history) do hist[#hist + 1] = tostring(h) end
  elseif opts.history_file then
    local f = io.open(opts.history_file, "r")
    if f then
      for line in f:lines() do if line ~= "" then hist[#hist + 1] = line end end
      f:close()
    end
  end
  return setmetatable({
    line = "", cursor = 0, history = hist, prompt = opts.prompt or PROMPT,
    _hpos = nil, _draft = nil, kill = "", stash = nil,
    _menu = nil, _search = nil, _hist_file = opts.history_file,
  }, Input)
end

function Input:_insert(str)
  if str == nil or str == "" then return end
  local bp = byteat(self.line, self.cursor)
  self.line = self.line:sub(1, bp - 1) .. str .. self.line:sub(bp)
  self.cursor = self.cursor + ulen(str)
  self:_refresh_menu()
end
function Input:_backspace()
  if self.cursor <= 0 then return end
  local a, b = byteat(self.line, self.cursor - 1), byteat(self.line, self.cursor)
  self.line = self.line:sub(1, a - 1) .. self.line:sub(b)
  self.cursor = self.cursor - 1
  self:_refresh_menu()
end
function Input:_delete()
  if self.cursor >= ulen(self.line) then return end
  local a, b = byteat(self.line, self.cursor), byteat(self.line, self.cursor + 1)
  self.line = self.line:sub(1, a - 1) .. self.line:sub(b)
  self:_refresh_menu()
end
function Input:_set(text)
  self.line = text or ""; self.cursor = ulen(self.line); self._menu = nil
end
function Input:paste(text) self:_insert(text or "") end

function Input:_bol()
  local i = self.cursor
  while i > 0 and cp_at(self.line, i - 1) ~= 10 do i = i - 1 end
  return i
end
function Input:_eol()
  local i, n = self.cursor, ulen(self.line)
  while i < n and cp_at(self.line, i) ~= 10 do i = i + 1 end
  return i
end
function Input:_word_left()
  local i = self.cursor
  while i > 0 and not is_word(cp_at(self.line, i - 1)) do i = i - 1 end
  while i > 0 and is_word(cp_at(self.line, i - 1)) do i = i - 1 end
  return i
end
function Input:_word_right()
  local i, n = self.cursor, ulen(self.line)
  while i < n and not is_word(cp_at(self.line, i)) do i = i + 1 end
  while i < n and is_word(cp_at(self.line, i)) do i = i + 1 end
  return i
end
function Input:_kill(from, to)
  if to <= from then return end
  local a, b = byteat(self.line, from), byteat(self.line, to)
  self.kill = self.line:sub(a, b - 1)
  self.line = self.line:sub(1, a - 1) .. self.line:sub(b)
  self.cursor = from
end

function Input:_history_up()
  local n = #self.history
  if n == 0 then return end
  if self._hpos == nil then self._draft = self.line; self._hpos = n
  elseif self._hpos > 1 then self._hpos = self._hpos - 1 end
  self:_set(self.history[self._hpos])
end
function Input:_history_down()
  if self._hpos == nil then return end
  if self._hpos < #self.history then
    self._hpos = self._hpos + 1; self:_set(self.history[self._hpos])
  else
    self._hpos = nil; self:_set(self._draft or ""); self._draft = nil
  end
end
function Input:_reset_history() self._hpos, self._draft = nil, nil end
function Input:_prev_line()
  local bol, col = self:_bol(), self.cursor - self:_bol()
  if bol <= 0 then self:_history_up(); return end
  local p_end = bol - 1
  local p_bol = p_end
  while p_bol > 0 and cp_at(self.line, p_bol - 1) ~= 10 do p_bol = p_bol - 1 end
  self.cursor = math.min(p_bol + col, p_end)
end
function Input:_next_line()
  local n = ulen(self.line)
  if self:_eol() >= n then self:_history_down(); return end
  local col = self.cursor - self:_bol()
  local nbol = self:_eol() + 1
  self.cursor = nbol
  self.cursor = math.min(nbol + col, self:_eol())
end
function Input:_save_hist(value)
  if value == "" then return end
  local h = self.history
  if h[#h] ~= value then h[#h + 1] = value end
  while #h > HISTORY_MAX do table.remove(h, 1) end
  if self._hist_file then
    local f = io.open(self._hist_file, "w")
    if f then f:write(table.concat(h, "\n")); if #h > 0 then f:write("\n") end; f:close() end
  end
end

local function common_prefix(items)
  local first = item_text(items[1])
  local n = #first
  for i = 2, #items do
    local t = item_text(items[i])
    local m, k = math.min(n, #t), 0
    while k < m and first:byte(k + 1) == t:byte(k + 1) do k = k + 1 end
    n = k
    if n == 0 then break end
  end
  return utf8_trim(first:sub(1, n))
end

function Input:_apply_item(item)
  local bp = byteat(self.line, self.cursor)
  local head, tail = self.line:sub(1, bp - 1), self.line:sub(bp)
  local word = head:match("(%S*)$") or ""
  local newhead = head:sub(1, #head - #word) .. item_text(item)
  self.line = newhead .. tail
  self.cursor = ulen(newhead)
end

function Input:_complete(opts)
  opts = opts or {}
  local apply = opts.apply_unique ~= false
  local hops = opts.hops or 0
  local bp = byteat(self.line, self.cursor)
  local head, tail = self.line:sub(1, bp - 1), self.line:sub(bp)
  local items = safe(bog.complete, head)
  if type(items) ~= "table" or #items == 0 then self._menu = nil; return end
  local word = head:match("(%S*)$") or ""
  if #items == 1 and apply then
    self:_apply_item(items[1])
    if item_text(items[1]):sub(-1) == "/" and hops < 8 then
      return self:_complete({ hops = hops + 1 })
    end
    self._menu = nil
    return
  end
  if apply and #items > 1 and hops < 8 then
    local lcp = common_prefix(items)
    if #lcp > #word and lcp:sub(1, #word) == word then
      local newhead = head:sub(1, #head - #word) .. lcp
      self.line = newhead .. tail
      self.cursor = ulen(newhead)
      return self:_complete({ hops = hops + 1 })
    end
  end
  self._menu = { items = items, sel = 1 }
end
function Input:_pick_menu()
  local m = self._menu
  if not m then return end
  local item = m.items[m.sel]
  self._menu = nil
  if not item then return end
  self:_apply_item(item)
  if item_text(item):sub(-1) == "/" then self:_complete() end
end
function Input:_refresh_menu()
  local bp = byteat(self.line, self.cursor)
  local word = self.line:sub(1, bp - 1):match("(%S*)$") or ""
  if word:sub(1, 1) == "@" or self._menu then
    self:_complete({ apply_unique = false })
  else
    self._menu = nil
  end
end

function Input:_ctrl(ch)
  ch = (ch or ""):lower()
  if ch == "a" then self.cursor = self:_bol()
  elseif ch == "e" then self.cursor = self:_eol()
  elseif ch == "b" then if self.cursor > 0 then self.cursor = self.cursor - 1 end
  elseif ch == "f" then if self.cursor < ulen(self.line) then self.cursor = self.cursor + 1 end
  elseif ch == "k" then self:_kill(self.cursor, self:_eol())
  elseif ch == "u" then self:_kill(self:_bol(), self.cursor)
  elseif ch == "w" then self:_kill(self:_word_left(), self.cursor)
  elseif ch == "y" then self:_insert(self.kill)
  elseif ch == "l" then return "redraw"
  elseif ch == "r" then self._search = { q = "", sel = 1 }; self._menu = nil; return "search"
  elseif ch == "s" then self.stash = self.line; self:_set(""); return "stash"
  elseif ch == "g" then return "editor"
  elseif ch == "d" then
    if self.line == "" then return "eof" end
    self:_delete()
  elseif ch == "c" then return "cancel"
  elseif ch == "n" then self:_history_down()
  elseif ch == "p" then self:_history_up()
  elseif ch == "j" then self:_insert("\n")
  end
end

function Input:_search_hits()
  local q = (self._search and self._search.q or ""):lower()
  local hits = {}
  for i = #self.history, 1, -1 do
    if q == "" or self.history[i]:lower():find(q, 1, true) then
      hits[#hits + 1] = self.history[i]
      if #hits >= 8 then break end
    end
  end
  return hits
end

function Input:key(ev)
  if type(ev) ~= "table" then return nil end
  if ev.type == "paste" then self:_insert(ev.text or ""); return nil end

  if self._search then
    local k = ev.key
    if k == "esc" or k == "escape" then self._search = nil; return nil end
    if k == "enter" then
      local hits = self:_search_hits()
      local pick = hits[self._search.sel]
      self._search = nil
      if pick then self:_set(pick) end
      return nil
    end
    if k == "up" then self._search.sel = math.max(1, self._search.sel - 1); return nil end
    if k == "down" then
      local n = #self:_search_hits()
      self._search.sel = math.min(n, self._search.sel + 1); return nil
    end
    if k == "backspace" then
      local q = self._search.q
      self._search.q = q:sub(1, math.max(0, #q - 1)); return nil
    end
    if k == "char" and ev.char then self._search.q = self._search.q .. ev.char end
    return nil
  end

  if self._menu then
    local k = ev.key
    if k == "esc" or k == "escape" then self._menu = nil; return nil end
    if k == "up" then self._menu.sel = math.max(1, self._menu.sel - 1); return nil end
    if k == "down" then self._menu.sel = math.min(#self._menu.items, self._menu.sel + 1); return nil
    end
    if k == "tab" and ev.shift then
      self._menu.sel = math.max(1, self._menu.sel - 1); return nil
    end
    if k == "tab" or k == "enter" then self:_pick_menu(); return nil end
  end

  local k = ev.key
  if k == "char" then
    if ev.alt then
      local c = (ev.char or ""):lower()
      if c == "b" then self.cursor = self:_word_left()
      elseif c == "f" then self.cursor = self:_word_right()
      elseif c == "d" then self:_kill(self.cursor, self:_word_right())
      else self:_insert(ev.char) end
    else
      self:_insert(ev.char)
    end
  elseif k == "backspace" then self:_backspace()
  elseif k == "delete" or k == "del" then self:_delete()
  elseif k == "left" then
    self.cursor = ev.alt and self:_word_left() or math.max(0, self.cursor - 1)
  elseif k == "right" then
    self.cursor = ev.alt and self:_word_right() or math.min(ulen(self.line), self.cursor + 1)
  elseif k == "home" then self.cursor = self:_bol()
  elseif k == "end" then self.cursor = self:_eol()
  elseif k == "up" then
    if self.line:find("\n", 1, true) then self:_prev_line() else self:_history_up() end
  elseif k == "down" then
    if self.line:find("\n", 1, true) then self:_next_line() else self:_history_down() end
  elseif k == "tab" then
    if not ev.shift then self:_complete() end
  elseif k == "enter" then
    if ev.shift or ev.alt or ev.ctrl then self:_insert("\n"); return nil end
    local value = self.line
    self:_save_hist(value)
    self.line, self.cursor = "", 0
    self:_reset_history()
    self._menu = nil
    return "submit", value
  elseif k == "ctrl" then
    return self:_ctrl(ev.char)
  elseif k == "esc" or k == "escape" then
    if self.line == "" then return "cancel", nil end
    self.line, self.cursor = "", 0
    self:_reset_history()
    self._menu = nil
  end
  return nil
end

function Input:_cells()
  local line = self.line
  local spans = safe(bog.repl_style, line) or {}
  local function fg_at(b)
    for _, sp in ipairs(spans) do
      local pos, len = sp.pos, sp.len
      if pos and len and b >= pos and b < pos + len then return STYLE_FG[sp.style] end
    end
    return nil
  end
  local cells = {}
  if utf8 then
    for bytepos, cp in utf8.codes(line) do
      cells[#cells + 1] = { ch = utf8.char(cp), fg = fg_at(bytepos - 1) }
    end
  else
    for i = 1, #line do cells[#cells + 1] = { ch = line:sub(i, i), fg = fg_at(i - 1) } end
  end
  return cells
end

local function coalesce(cells, from, to)
  local runs, i = {}, from
  while i <= to do
    local fg, buf = cells[i].fg, { cells[i].ch }
    i = i + 1
    while i <= to and cells[i].fg == fg do buf[#buf + 1] = cells[i].ch; i = i + 1 end
    runs[#runs + 1] = { text = table.concat(buf), fg = fg, bg = nil, attr = nil }
  end
  return runs
end

-- Single-row view used by tests: prompt + coloured text, horizontally scrolled
-- so the cursor stays visible. Newlines render as the glyph the tests never see.
function Input:runs(width)
  local cells = self:_cells()
  local total, pw = #cells, ulen(self.prompt)
  local avail = (width and width > pw) and (width - pw) or nil
  local start = 0
  if avail and total > avail then
    if self.cursor > avail then start = self.cursor - avail end
    if start > total - avail then start = total - avail end
    if start < 0 then start = 0 end
  end
  local last = avail and math.min(total, start + avail) or total
  local runs = { { text = self.prompt, fg = nil, bg = nil, attr = nil } }
  for _, r in ipairs(coalesce(cells, start + 1, last)) do runs[#runs + 1] = r end
  return runs, pw + (self.cursor - start)
end

-- Wrapped visual rows for the frame. First return is a list of Contract-B lines.
function Input:visual(width)
  width = math.max(8, width or 80)
  local cells = self:_cells()
  local pw = vis_w(self.prompt)
  local inner = math.max(4, width - pw)
  local phys, cur = { {} }, 1
  for _, c in ipairs(cells) do
    if c.ch == "\n" then phys[#phys + 1] = {}; cur = #phys
    else
      local row = phys[cur]
      row[#row + 1] = c
    end
  end
  -- Map cursor (codepoint index) onto a physical line + column.
  local cpi, p_i, p_col = 0, 1, 0
  for pi, row in ipairs(phys) do
    local n = #row
    if self.cursor <= cpi + n then p_i, p_col = pi, self.cursor - cpi; break end
    cpi = cpi + n + 1 -- the newline
    p_i, p_col = pi, n
  end
  local vis, cursor_row, cursor_col = {}, 1, pw
  for pi, row in ipairs(phys) do
    local chunks, i = {}, 1
    if #row == 0 then
      chunks[1] = { from = 1, to = 0, cells = {} }
    else
      while i <= #row do
        local w, j = 0, i
        while j <= #row do
          local cw = vis_w(row[j].ch)
          if w + cw > inner and w > 0 then break end
          w = w + cw; j = j + 1
        end
        chunks[#chunks + 1] = { from = i, to = j - 1 }
        i = j
      end
    end
    for ci, ch in ipairs(chunks) do
      local prefix = (#vis == 0) and self.prompt or string.rep(" ", pw)
      local line = { { text = prefix } }
      if ch.to >= ch.from then
        for _, r in ipairs(coalesce(row, ch.from, ch.to)) do line[#line + 1] = r end
      end
      vis[#vis + 1] = line
      if pi == p_i and p_col >= (ch.from - 1) and p_col <= ch.to then
        local col_w = 0
        for k = ch.from, p_col do
          if row[k] then col_w = col_w + vis_w(row[k].ch) end
        end
        cursor_row, cursor_col = #vis, pw + col_w
      end
    end
  end
  if #vis == 0 then vis[1] = { { text = self.prompt } } end
  if #vis > VISUAL_MAX then
    local drop = #vis - VISUAL_MAX
    local kept = {}
    for i = drop + 1, #vis do kept[#kept + 1] = vis[i] end
    vis = kept
    cursor_row = math.max(1, cursor_row - drop)
  end
  cursor_row = math.max(1, math.min(#vis, cursor_row))
  return vis, cursor_row, cursor_col
end

function Input:menu_runs(width)
  local m = self._menu
  if not m then return {} end
  local maxn = math.min(#m.items, 8)
  m.offset = math.max(0, math.min(m.sel - 1, #m.items - maxn))
  local out = {}
  for i = 1, maxn do
    local idx = m.offset + i
    local it = m.items[idx]
    if not it then break end
    local sel = idx == m.sel
    local mark = sel and "▸ " or "  "
    local help = (type(it) == "table" and it.help) and ("  " .. it.help) or ""
    out[#out + 1] = {
      { text = mark .. item_text(it), fg = MENU_FG, bg = sel and MENU_BG or nil,
        attr = sel and { bold = true } or nil },
      { text = help, fg = DIM, bg = sel and MENU_BG or nil },
    }
  end
  return out
end

function Input:search_runs(width)
  if not self._search then return {} end
  local hits = self:_search_hits()
  if self._search.sel > #hits then self._search.sel = math.max(1, #hits) end
  local out = { { { text = "search: " .. self._search.q, fg = MENU_FG } } }
  for i, h in ipairs(hits) do
    local sel = i == self._search.sel
    out[#out + 1] = { { text = (sel and "▸ " or "  ") .. h, fg = MENU_FG,
      bg = sel and MENU_BG or nil } }
  end
  return out
end

function Input:overlay_runs(width)
  if self._search then return self:search_runs(width) end
  if self._menu then return self:menu_runs(width) end
  return {}
end

return M
