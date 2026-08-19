-- agentcomplete.lua -- composer Tab completion for AgentView.
--
-- Same engine as the cTUI (bog.complete): Tab with several hits opens a pick
-- menu, `@` file references filter as you type, a unique directory keeps
-- descending, `/` offers commands and skills. Pure operations on the view's
-- line table; the overlay is drawn by draw().
local style = require "core.style"
local common = require "core.common"
local widgets = require "core.widgets"
local difflib = require "core.diff"

local M = {}

local MENU_MAX = 8

local function item_text(it)
  if type(it) == "table" then return it.text or "" end
  return tostring(it or "")
end

local function item_label(it)
  if type(it) ~= "table" then return tostring(it or "") end
  local t = it.display or it.text or ""
  if it.help and it.help ~= "" then return t .. "  " .. tostring(it.help) end
  return t
end

local function utf8_trim(s)
  if not utf8 then return s end
  while #s > 0 and not utf8.len(s) do s = s:sub(1, #s - 1) end
  return s
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

local function split_lines(s)
  local lines = difflib.lines(s)
  if #lines == 0 then lines = { "" } end
  return lines
end

-- Draft text from the start of the buffer to the caret.
function M.prefix(view)
  local parts = {}
  for i = 1, (view.cy or 1) - 1 do parts[#parts + 1] = view.lines[i] or "" end
  parts[#parts + 1] = (view.lines[view.cy] or ""):sub(1, (view.cx or 1) - 1)
  return table.concat(parts, "\n")
end

function M.suffix(view)
  local parts = { (view.lines[view.cy] or ""):sub(view.cx or 1) }
  for i = (view.cy or 1) + 1, #(view.lines or {}) do
    parts[#parts + 1] = view.lines[i] or ""
  end
  return table.concat(parts, "\n")
end

-- Place the caret at byte offset `at` (1-based, end-of-prefix is #prefix+1)
-- in a reconstructed multiline string.
local function place(view, full, at)
  view.lines = split_lines(full)
  local cy, seen = 1, 0
  at = math.max(1, math.min(at, #full + 1))
  for i, line in ipairs(view.lines) do
    local line_end = seen + #line + 1 -- the newline (or EOF on last)
    if at <= line_end or i == #view.lines then
      cy = i
      view.cy = cy
      view.cx = at - seen
      if view.cx < 1 then view.cx = 1 end
      if view.cx > #line + 1 then view.cx = #line + 1 end
      return
    end
    seen = seen + #line + 1
  end
  view.cy = #view.lines
  view.cx = #(view.lines[view.cy] or "") + 1
end

function M.apply_item(view, item)
  local head, tail = M.prefix(view), M.suffix(view)
  local word = head:match("(%S*)$") or ""
  local newhead = head:sub(1, #head - #word) .. item_text(item)
  place(view, newhead .. tail, #newhead + 1)
end

function M.complete(view, opts)
  opts = opts or {}
  local apply = opts.apply_unique ~= false
  local hops = opts.hops or 0
  local head = M.prefix(view)
  if type(bog) ~= "table" or type(bog.complete) ~= "function" then
    view._complete_menu = nil
    return
  end
  local ok, items = pcall(bog.complete, head)
  if not ok or type(items) ~= "table" or #items == 0 then
    view._complete_menu = nil
    return
  end
  local word = head:match("(%S*)$") or ""
  if #items == 1 and apply then
    M.apply_item(view, items[1])
    if item_text(items[1]):sub(-1) == "/" and hops < 8 then
      return M.complete(view, { hops = hops + 1 })
    end
    view._complete_menu = nil
    return
  end
  if apply and #items > 1 and hops < 8 then
    local lcp = common_prefix(items)
    if #lcp > #word and lcp:sub(1, #word) == word then
      local tail = M.suffix(view)
      local newhead = head:sub(1, #head - #word) .. lcp
      place(view, newhead .. tail, #newhead + 1)
      return M.complete(view, { hops = hops + 1 })
    end
  end
  view._complete_menu = { items = items, sel = 1 }
end

function M.pick(view)
  local m = view._complete_menu
  if not m then return end
  local item = m.items[m.sel]
  view._complete_menu = nil
  if not item then return end
  M.apply_item(view, item)
  if item_text(item):sub(-1) == "/" then M.complete(view) end
end

function M.refresh(view)
  local word = M.prefix(view):match("(%S*)$") or ""
  if word:sub(1, 1) == "@" or view._complete_menu then
    M.complete(view, { apply_unique = false })
  else
    view._complete_menu = nil
  end
end

function M.dismiss(view)
  view._complete_menu = nil
end

-- If `@path` is not a real file, ask the completer for a unique file hit so
-- `@complete` can attach lua/complete.lua the way Tab would have filled it in.
function M.resolve_mention(path)
  if type(bog) ~= "table" or type(bog.complete) ~= "function" then return nil end
  local ok, items = pcall(bog.complete, "@" .. path)
  if not ok or type(items) ~= "table" then return nil end
  local files = {}
  for _, it in ipairs(items) do
    local t = item_text(it)
    if t:sub(1, 1) == "@" and t:sub(-1) ~= "/" then
      files[#files + 1] = t:sub(2)
    end
  end
  if #files == 1 then return files[1] end
  return nil
end

function M.on_key(view, key)
  if view.edit_mode == "normal" and key ~= "shift+tab" then return false end
  local m = view._complete_menu
  if m then
    if key == "escape" then
      M.dismiss(view); return true
    elseif key == "up" then
      m.sel = math.max(1, m.sel - 1); return true
    elseif key == "down" then
      m.sel = math.min(#m.items, m.sel + 1); return true
    elseif key == "shift+tab" then
      m.sel = math.max(1, m.sel - 1); return true
    elseif key == "tab" or key == "return" then
      M.pick(view); return true
    end
  end
  if key == "tab" then
    M.complete(view)
    return true
  end
  return false
end

-- Overlay above the composer. Hits are appended onto view.hits so a click
-- picks the row the same way a toolbar button does.
function M.draw(view, box)
  local m = view._complete_menu
  if not m or not m.items or #m.items == 0 then return end
  local font, x, w, iy = box.font, box.x, box.w, box.y
  local lh = box.lh
  local pad = box.pad or 0
  local n = math.min(#m.items, MENU_MAX)
  local h = n * lh + pad
  local top = iy - h
  renderer.draw_rect(x - pad / 2, top, w + pad, h, style.background2)
  renderer.draw_rect(x - pad / 2, top, w + pad, 1, style.divider)
  for i = 1, n do
    local it = m.items[i]
    local yy = top + (i - 1) * lh
    local hover = view.mouse and widgets.inside(
      { x = x, y = yy, w = w, h = lh }, view.mouse.x, view.mouse.y)
    if i == m.sel or hover then
      renderer.draw_rect(x - pad / 2, yy, w + pad, lh, style.selection)
    end
    common.draw_text(font, style.text, item_label(it), "left", x, yy, w, lh)
    view.hits[#view.hits + 1] = {
      x = x, y = yy, w = w, h = lh,
      item = { label = "complete:" .. item_text(it), action = function()
        m.sel = i
        M.pick(view)
      end },
    }
  end
end

return M
