-- choose.lua -- unique keys, wrap/hang runs, and prose auto-capture
-- (detect enumerated questions, present after a turn).
local choose = require("choose")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- ---- detect: lettered lists ------------------------------------------------
local d = choose.detect([[
Which approach should we take?

a) Use SQLite for storage
b) Use the filesystem
c) Something else entirely
]])
ok(d and d.prompt:find("Which approach"), "detect: lettered list finds prompt")
ok(d and #d.options == 3 and d.options[1].label:find("SQLite"), "detect: lettered options")

-- ---- detect: numbered lists ------------------------------------------------
d = choose.detect("Pick one:\n\n1. Fix the bug first\n2. Add tests first\n3. Refactor")
ok(d and #d.options == 3 and d.options[2].label:find("tests"), "detect: numbered list")

-- ---- detect: bullets -------------------------------------------------------
d = choose.detect("Would you prefer:\n- Fast iteration\n- Maximum safety")
ok(d and #d.options == 2, "detect: bullet list")

-- ---- detect: rejects -------------------------------------------------------
ok(choose.detect("Just a single bullet:\n- only one") == nil, "detect: one item rejected")
ok(choose.detect("No options here, just a question?") == nil, "detect: bare question rejected")
ok(choose.detect([[
```lua
a) not a real option
b) inside a fence
```
]]) == nil, "detect: options inside code fence ignored")

-- ---- build + render --------------------------------------------------------
local rec, err = choose.build({
  prompt = "Which?",
  options = { { label = "yes" }, { label = "no" } },
})
ok(rec and not err, "build: valid record")
ok(rec.options[1].key == "a" and rec.options[2].key == "b", "build: assigns letter keys")
ok(choose.render(rec):find("a%) yes"), "render: lettered menu")

ok(choose.parse_line(rec, "a").index == 1, "parse_line: letter picks option")
ok(choose.parse_line(rec, "maybe").text == "maybe", "parse_line: free text")
ok(choose.parse_line(rec, "").cancel == true, "parse_line: empty cancels")

-- Duplicate requested keys get unique letters.
local dup = choose.build({
  options = {
    { label = "one", key = "a" },
    { label = "two", key = "a" },
    { label = "three" },
  },
})
ok(dup.options[1].key == "a" and dup.options[2].key == "b" and dup.options[3].key == "c",
   "build: duplicate keys are uniqued")

-- Numbered keys still answer to positional a/b.
local num = choose.build({
  options = { { label = "fix", key = "1" }, { label = "tests", key = "2" } },
})
ok(num.options[1].key == "1", "build: keeps explicit numbered key")
ok(choose.index_for_key(num, "1") == 1, "index_for_key: digit")
ok(choose.index_for_key(num, "a") == 1, "index_for_key: positional letter on numbered menu")
ok(choose.parse_line(num, "b").index == 2, "parse_line: positional letter")

-- Wrapped runs hang under the marker instead of clipping.
local wide = choose.build({
  prompt = "Pick a path",
  options = {
    { label = "a quite long option label that should wrap onto the next line" },
    { label = "short" },
  },
})
local runs = choose.runs(wide, 24)
ok(#runs >= 4, "runs: wraps a long option")
local function line_text(ln)
  local t = {}
  for _, r in ipairs(ln) do t[#t + 1] = r.text end
  return table.concat(t)
end
local found_hang = false
for _, ln in ipairs(runs) do
  local s = line_text(ln)
  if s:match("^%s+%S") and not s:match("^%s+[a-z0-9]%)") then found_hang = true end
end
ok(found_hang, "runs: continuation rows hanging-indent under a)")
local max = 0
for _, ln in ipairs(runs) do
  local n = 0
  for _, r in ipairs(ln) do n = n + (sys.width and sys.width(r.text) or #r.text) end
  if n > max then max = n end
end
ok(max <= 24, "runs: no line exceeds width (max " .. max .. ")")

-- Plain render at a column width wraps the same way (the scrolling REPL path).
local rendered = choose.render(wide, 24)
ok(rendered:find("a%) "), "render(width): keeps the lettered marker")
local rmax = 0
for line in (rendered .. "\n"):gmatch("(.-)\n") do
  local n = (sys.width and sys.width(line)) or #line
  if n > rmax then rmax = n end
end
ok(rmax <= 24, "render(width): no line exceeds width (max " .. rmax .. ")")

-- A multi-line prompt stays two source lines, not one flattened paragraph.
local multi = choose.build({
  prompt = "First line of the question\nAnd a second line",
  options = { { label = "yes" }, { label = "no" } },
})
local mtext = choose.render(multi, 40)
ok(mtext:find("First line of the question") and mtext:find("And a second line"),
   "render: keeps prompt newlines")
ok(not mtext:find("First line of the question And a second"),
   "render: does not flatten prompt newlines into one paragraph")

-- Narrow and wide columns both stay inside the budget.
for _, w in ipairs({ 20, 32, 40, 80 }) do
  local rs = choose.runs(wide, w)
  local worst = 0
  for _, ln in ipairs(rs) do
    local n = 0
    for _, r in ipairs(ln) do n = n + ((sys.width and sys.width(r.text)) or #r.text) end
    if n > worst then worst = n end
  end
  ok(worst <= w, "runs: width " .. w .. " (max " .. worst .. ")")
end

-- ---- format_user_reply -----------------------------------------------------
ok(choose.format_user_reply(rec, { index = 2 }) == "no", "format_user_reply: index")
ok(choose.format_user_reply(rec, { text = "custom" }) == "custom", "format_user_reply: text")
ok(choose.format_user_reply(rec, { cancel = true }) == nil, "format_user_reply: cancel")

-- ---- session capture -------------------------------------------------------
local sess = { messages = {
  { role = "user", content = "help" },
  { role = "assistant", content = "Which?\n\na) one\nb) two" },
}}
ok(choose.capture_from_session(sess) ~= nil, "capture_from_session: finds trailing list")
local sess2 = { messages = {
  { role = "assistant", content = {
    { type = "text", text = "Which?\n\na) one\nb) two" },
    { type = "tool_use", name = "choose", id = "1", input = {} },
  }},
}}
ok(choose.capture_from_session(sess2) == nil, "capture_from_session: skips after choose tool")

-- ---- sync capture (REPL path) ----------------------------------------------
bog.choose_ask = function(r)
  return choose.parse_line(r, "b")
end
local reply = choose.capture_after_turn({ messages = {
  { role = "assistant", content = "Pick:\n\na) alpha\nb) beta" },
}})
ok(reply == "beta", "capture_after_turn: sync REPL returns chosen label")

io.write(string.format("choose: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
