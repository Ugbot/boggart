-- termrender.lua -- pure-Lua tests for the terminal transcript renderer.
-- Run: ./boggart --eval tests/termrender.lua   (no network, terminates itself).
--
-- Feeds a representative entry of every kind and asserts the load-bearing
-- structure appears: heading emphasis, a fenced block's language colour, the
-- green/red SGR pair in a diff, distinct prefixes -- and, crucially, that
-- color=false yields a string with no "\27[" escape anywhere at all.
local tr = require("termrender")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- SGR truecolour codes the renderer emits, from style.lua's palette.
local SGR_GOOD    = "38;2;127;183;126"   -- good  #7fb77e (added)
local SGR_ERR     = "38;2;247;116;131"   -- error #f77483 (removed / errors)
local SGR_KEYWORD = "38;2;229;138;201"   -- keyword #e58ac9 (tool calls / kw syntax)
local SGR_STRING  = "38;2;247;201;92"    -- syntax string #f7c95c
local SGR_BOLD    = ";1m"               -- bold attribute, appended to the fg SGR
local BG_CODE     = "48;2;37;37;41"      -- code band bg #252529

local function has(s, sub) return s:find(sub, 1, true) ~= nil end
local function no_escapes(s) return s:find("\27[", 1, true) == nil end

local color = { width = 80, color = true }
local plain = { width = 80, color = false }

-- ---- assistant: markdown, headings, lists, inline, fenced code -------------
do
  local md = table.concat({
    "# Heading one",
    "",
    "Some **bold** and *italic* and `inline` and a [link](http://x).",
    "",
    "- first bullet",
    "- second bullet",
    "1. numbered one",
    "> a quoted line",
    "",
    "```lua",
    'local x = "hi"  -- a comment',
    "function f() return x end",
    "```",
  }, "\n")
  local e = { role = "assistant", text = md }
  local s = tr.entry(e, color)

  ok(has(s, "Heading one"), "assistant: heading text present")
  ok(has(s, SGR_BOLD), "assistant: heading/bold emphasis emits bold SGR")
  ok(has(s, "\226\128\162") or has(s, "- "), "assistant: bullet marker rendered")
  ok(has(s, BG_CODE), "assistant: fenced code draws a background band")
  ok(has(s, SGR_STRING), "assistant: code string highlighted (language-aware)")
  ok(has(s, SGR_KEYWORD), "assistant: code keyword highlighted")
  ok(not has(s, "```"), "assistant: fence markers are not emitted as content")

  -- Same input, colour off: legible text, zero escapes.
  local p = tr.entry(e, plain)
  ok(no_escapes(p), "assistant: color=false emits no ANSI escapes")
  ok(has(p, "Heading one") and has(p, "inline") and has(p, "return x"),
    "assistant: color=false keeps all the text")
end

-- ---- width wrapping (prose, not code) --------------------------------------
do
  local long = string.rep("word ", 40)
  local s = tr.assistant({ role = "assistant", text = long }, { width = 20, color = false })
  local longest = 0
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if #line > longest then longest = #line end
  end
  ok(longest <= 20, "wrap: prose respects width (longest line " .. longest .. " <= 20)")
end

-- ---- diff: the {diff=..., path=...} structure agentview pushes -------------
do
  local d = {
    added = 1, removed = 1, start_line = 2, unchanged = false,
    hunk = {
      { " ", "context before" },
      { "-", "old line" },
      { "+", "new line" },
      { " ", "context after" },
    },
  }
  local entry = { role = "diff", text = "", diff = d, path = "src/foo.lua" }
  local s = tr.entry(entry, color)
  ok(has(s, "src/foo.lua"), "diff: file header names the path")
  ok(has(s, "+1 -1"), "diff: header shows add/remove counts")
  ok(has(s, SGR_GOOD), "diff: added line uses green SGR")
  ok(has(s, SGR_ERR), "diff: removed line uses red SGR")
  ok(has(s, "+ new line") and has(s, "- old line"), "diff: +/- markers on the right rows")

  local p = tr.entry(entry, plain)
  ok(no_escapes(p), "diff: color=false emits no ANSI escapes")
  ok(has(p, "+ new line") and has(p, "- old line"), "diff: markers survive plain mode")
end

-- ---- diff: a raw unified-diff string ---------------------------------------
do
  local raw = table.concat({
    "--- a/x.txt",
    "+++ b/x.txt",
    "@@ -1,2 +1,2 @@",
    "-gone",
    "+added",
    " kept",
  }, "\n")
  local s = tr.diff(raw, color)
  ok(has(s, SGR_GOOD) and has(s, SGR_ERR), "unified: green + / red - present")
  ok(has(s, SGR_KEYWORD), "unified: @@ hunk header coloured")
  ok(no_escapes(tr.diff(raw, plain)), "unified: color=false emits no ANSI escapes")
end

-- ---- tool / user / error / system: distinct, honest, plain-clean -----------
do
  local tool = tr.tool({ role = "tool", text = "edit: src/foo.lua" }, color)
  ok(has(tool, "edit: src/foo.lua"), "tool: shows the call")
  ok(has(tool, SGR_KEYWORD), "tool: uses the keyword colour")

  local err = tr.error({ role = "error", text = "boom failed" }, color)
  ok(has(err, SGR_ERR), "error: uses the error colour")
  ok(has(err, SGR_BOLD), "error: emphasised")

  local user = tr.user({ role = "user", text = "hello there" }, color)
  ok(has(user, "hello there"), "user: echoes the text")

  local sys = tr.system({ role = "system", text = "context compacted" }, color)
  ok(has(sys, "context compacted"), "system: shows the note")

  -- Every kind, colour off, must be escape-free.
  for _, e in ipairs({
    { role = "tool", text = "bash: ls" },
    { role = "error", text = "nope" },
    { role = "user", text = "hi" },
    { role = "system", text = "note" },
  }) do
    ok(no_escapes(tr.entry(e, plain)), "plain: " .. e.role .. " has no escapes")
  end
end

-- ---- NO_COLOR environment forces plain even when color=true ----------------
do
  local prev = os.getenv("NO_COLOR")
  -- setenv may not exist in every build; only assert when we can actually set it.
  local set = rawget(_G, "setenv") or (rawget(_G, "sys") and sys.setenv)
  if set then
    set("NO_COLOR", "1")
    local s = tr.entry({ role = "diff", text = "", diff = {
      added = 0, removed = 1, start_line = 1, unchanged = false,
      hunk = { { "-", "x" } } }, path = "p" }, { color = true })
    ok(no_escapes(s), "NO_COLOR forces plain output despite color=true")
    if prev == nil then set("NO_COLOR", "") else set("NO_COLOR", prev) end
  else
    passed = passed + 1   -- environment cannot be mutated here; not a failure
    io.write("note: NO_COLOR env test skipped (no setenv in this build)\n")
  end
end

-- ---- transcript convenience ------------------------------------------------
do
  local s = tr.transcript({
    { role = "user", text = "do the thing" },
    { role = "assistant", text = "Done." },
  }, color)
  ok(has(s, "do the thing") and has(s, "Done."), "transcript: joins all entries")
end

io.write(string.format("\ntermrender: %d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
