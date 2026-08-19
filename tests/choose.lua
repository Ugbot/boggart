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

io.write(string.format("choose: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
