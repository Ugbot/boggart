-- choose.lua -- choice menus: unique keys, wrap/hang runs, key picking.
local choose = require("choose")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

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

io.write(string.format("choose: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
