-- story/view.lua -- how a book LOOKS in the TUI (and, later, the studio): one
-- view model per screen, plain text renderers. Same rules as tracker_view:
-- readability over decoration, status is a glyph PLUS a word, no line wider
-- than the terminal.
--
--   /story                 the books: chapters, words (of target)
--   /story chapters [book] the chapter navigator
--   /story <noun> <action> key=value ...   any `story` tool call
local sb = require("story.book")
local si = require("story.index")
local tv = require("tracker_view")
local M = {}

M.GLYPH = { draft = "◐", done = "✓" }
local dw, wrap = tv.display_width, tv.wrap

local function fit(s, width)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if dw(line) <= width then out[#out + 1] = line
    else
      local ind = line:match("^(%s*)")
      for i, l in ipairs(wrap(line, width - #ind)) do out[#out + 1] = (i == 1 and ind or ind .. "  ") .. l end
    end
  end
  return table.concat(out, "\n")
end
M.fit = fit

-- ---- models -------------------------------------------------------------------------
function M.books_model()
  local out = {}
  for _, b in ipairs(sb.list()) do
    si.fresh(b)
    local t = require("story.core").totals(b)
    out[#out + 1] = { name = b.name, title = b.m.title or b.name, root = b.root, chapters = t.chapters,
                      done = t.done, words = t.words, target = b.m.target_words }
  end
  return out
end

function M.chapters_model(spec)
  local b, e = sb.resolve(spec)
  if not b then return nil, e end
  si.fresh(b)
  local rows, words, done = {}, 0, 0
  for _, c in ipairs(si.chapters(b)) do
    local st = c.done == 1 and "done" or "draft"
    if st == "done" then done = done + 1 end
    words = words + (c.words or 0)
    rows[#rows + 1] = { n = c.n, label = c.label ~= "" and c.label or nil, status = st, glyph = M.GLYPH[st],
                        title = (c.title ~= "" and c.title) or c.path, words = c.words or 0, path = c.path,
                        variant = c.variant,
                        shrunk = si.shrunk(c) and { words = c.longest, variant = c.longest_variant } or nil }
  end
  local shrunk = 0
  for _, r in ipairs(rows) do if r.shrunk then shrunk = shrunk + 1 end end
  return { name = b.name, title = b.m.title or b.name, rows = rows, words = words, done = done,
           target = b.m.target_words, shrunk = shrunk }
end

-- ---- renderers ----------------------------------------------------------------------
local function words_of(n, target)
  if target and target > 0 then return string.format("%d / %d words (%d%%)", n, target, math.floor(100 * n / target)) end
  return string.format("%d words", n)
end

function M.render_books(model, width)
  if #model == 0 then return "No books yet. In a book's directory: /story book init" end
  local out = {}
  for _, b in ipairs(model) do
    out[#out + 1] = b.name .. (b.title ~= b.name and ("  — " .. b.title) or "")
    out[#out + 1] = string.format("  %d chapters (%d done), %s", b.chapters, b.done, words_of(b.words, b.target))
    out[#out + 1] = "  " .. b.root
  end
  return fit(table.concat(out, "\n"), width)
end

function M.render_chapters(m, width)
  local out = { m.title .. "  (" .. m.name .. ")",
    string.format("%d chapters: %d done, %d in draft — %s", #m.rows, m.done, #m.rows - m.done, words_of(m.words, m.target)) }
  if (m.shrunk or 0) > 0 then
    out[#out + 1] = string.format("! %d chapter(s) read from a variant much shorter than another (see !)", m.shrunk)
  end
  out[#out + 1] = ""
  local numw = 3
  for _, r in ipairs(m.rows) do
    local lead = string.format("%s %" .. numw .. "s ", r.glyph, r.label or tostring(r.n))
    local tail = string.format("  %6d  %s", r.words, r.status)
    local room = width - dw(lead) - dw(tail)
    if room >= 12 then
      local t = wrap(r.title, room)
      out[#out + 1] = lead .. t[1] .. string.rep(" ", room - dw(t[1])) .. tail
      for i = 2, #t do out[#out + 1] = string.rep(" ", dw(lead)) .. t[i] end
    else
      out[#out + 1] = lead .. r.status
      for _, l in ipairs(wrap(r.title .. " — " .. r.words .. " words", width - 4)) do out[#out + 1] = "    " .. l end
    end
    if r.shrunk then
      local v = r.shrunk.variant == "" and "the base file" or ("the " .. r.shrunk.variant .. " file")
      local msg = string.format("! %s is SHORTER than %s (%d vs %d words)", r.variant == "" and "this" or r.variant,
        v, r.words, r.shrunk.words)
      for _, l in ipairs(wrap(msg, width - dw(lead))) do out[#out + 1] = string.rep(" ", dw(lead)) .. l end
    end
  end
  if #m.rows == 0 then out[#out + 1] = "(no chapters matched the manifest: /story book check_layout)" end
  return fit(table.concat(out, "\n"), width)
end

-- ---- the command -----------------------------------------------------------------------
-- "key=value" words (quotes allowed around a value) into a table.
function M.parse_kv(s)
  local a = {}
  local i = 1
  while i <= #s do
    local k, rest = s:match("^%s*([%w_]+)=()", i)
    if not k then
      local w, nx = s:match("^%s*(%S+)()", i)
      if not w then break end
      a[#a + 1] = w; i = nx
    else
      local j = rest
      local v
      local qch = s:sub(j, j)
      if qch == '"' or qch == "'" then
        local close = s:find(qch, j + 1, true) or (#s + 1)
        v = s:sub(j + 1, close - 1); i = close + 1
      else
        v, i = s:match("^(%S*)()", j)
      end
      if v == "true" then v = true elseif v == "false" then v = false end
      a[k] = v
    end
  end
  return a
end

M.HELP = table.concat({
  "/story                          the books",
  "/story chapters [book]          chapter navigator",
  "/story <noun> <action> k=v ...  any story tool call, e.g.",
  "    /story book init path=~/novel      /story book check_layout",
  "    /story search query=\"red door\"    /story character get name=vera",
  "    /story chapter get n=7             /story style check n=7",
}, "\n")

function M.command(args, width)
  args = args or ""
  width = width or 80
  local a = M.parse_kv(args)
  local first = a[1]
  if not first then return M.render_books(M.books_model(), width) end
  if first == "help" then return M.HELP end
  if first == "chapters" then
    local m, e = M.chapters_model(a[2] or a.book)
    return m and M.render_chapters(m, width) or ("story: " .. e)
  end
  local sc = require("story.core")
  if sc.ACTIONS[first] then
    a.noun, a.action = first, a[2]
    a[1], a[2] = nil, nil
    a._author = true   -- typed by the author: writes are canon, proposals can be decided
    return fit(sc.call(a), width)
  end
  return "story: unknown '" .. first .. "'\n" .. M.HELP
end

return M
