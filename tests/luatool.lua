-- luatool.lua -- the Lua-native answer to shelling out to python: the C-backed
-- regex/glob primitives (sys.re_find/re_gsub/glob), their gold wrappers
-- (gold.re, gold.fs.glob/find), and the `lua` eval tool that ties them together.
local tools = require("tools")
local gold = require("gold")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- ---- C primitives: sys.re_find / re_gsub -----------------------------------
do
  local s, e, c1, c2 = sys.re_find("hello world 42", "([a-z]+) ([a-z]+)")
  eq(s, 1, "re_find start offset")
  eq(e, 11, "re_find end offset (inclusive)")
  eq(c1, "hello", "re_find capture 1")
  eq(c2, "world", "re_find capture 2")

  ok(sys.re_find("HELLO", "hello", "i"), "re_find case-insensitive flag")
  ok(not sys.re_find("HELLO", "hello"), "re_find is case-sensitive by default")

  local s2 = sys.re_find("abc 123 def 456", "[0-9]+", "", 8)
  eq(s2, 13, "re_find resumes from init (finds the second run of digits)")

  local nofind, err = sys.re_find("x", "[unclosed")
  eq(nofind, nil, "re_find nil on bad pattern")
  ok(type(err) == "string", "re_find returns an error message on bad pattern")
end
do
  local out, n = sys.re_gsub("a1b2c3", "[0-9]", "#")
  eq(out, "a#b#c#", "re_gsub replaces all")
  eq(n, 3, "re_gsub returns the count")

  local swapped = sys.re_gsub("John Smith", "([A-Za-z]+) ([A-Za-z]+)", "\\2 \\1")
  eq(swapped, "Smith John", "re_gsub backreferences")

  local once = sys.re_gsub("aaa", "a", "b", "", 1)
  eq(once, "baa", "re_gsub honours max count")
end

-- ---- gold.re wrappers ------------------------------------------------------
do
  ok(gold.re.test("foo123", "[0-9]+"), "gold.re.test true")
  ok(not gold.re.test("foo", "[0-9]+"), "gold.re.test false")
  eq(gold.re.match("key=value", "=([a-z]+)"), "value", "gold.re.match returns the capture")
  local all = gold.re.all("a1 b2 c33", "[0-9]+")
  eq(#all, 3, "gold.re.all count")
  eq(all[3], "33", "gold.re.all captured multi-digit")
  local joined = {}
  for k, v in gold.re.gmatch("x=1;y=2", "([a-z])=([0-9])") do joined[#joined + 1] = k .. v end
  eq(table.concat(joined, ","), "x1,y2", "gold.re.gmatch yields multiple captures")
end

-- ---- gold.fs.glob / find ---------------------------------------------------
do
  local g = gold.fs.glob("lua/gold/*.lua")
  ok(#g >= 5, "gold.fs.glob finds the gold modules (" .. #g .. ")")
  local hit = false
  for _, p in ipairs(g) do if p:find("re%.lua$") then hit = true end end
  ok(hit, "gold.fs.glob includes gold/re.lua")

  -- gold.fs.find's string form is a POSIX regex over the basename (ERE syntax)
  local found = gold.fs.find("lua/gold", "re\\.lua$")
  ok(#found >= 1, "gold.fs.find locates by basename regex")
end

-- ---- the `lua` tool --------------------------------------------------------
do
  eq(tools.run("lua", { code = "1 + 2 * 3" }), "7", "lua tool: expression form")
  eq(tools.run("lua", { code = "return 'hi'" }), "hi", "lua tool: explicit return")
  eq(tools.run("lua", { code = "print('a'); print('b')" }), "a\nb", "lua tool: captures print()")
  eq(tools.run("lua", { code = "gold.re.all('a1 b2', '[0-9]')" }), '["1","2"]',
     "lua tool: table result is JSON-encoded")
  ok(tools.run("lua", { code = "error('boom')" }):find("Tool error:"),
     "lua tool: runtime error surfaces as a tool error")
  ok(tools.run("lua", { code = "this is not lua(" }):find("compile"),
     "lua tool: compile error reported")
  ok(tools.run("lua", { code = "while true do end" }):find("budget"),
     "lua tool: runaway loop trips the instruction budget (no hang)")
  -- capable but isolated: it can read files (via gold.fs) yet cannot clobber a
  -- harness global (writes land in its own env, not _G)
  ok(tonumber(tools.run("lua", { code = "#gold.fs.read('lua/gold/re.lua')" })) > 100,
     "lua tool: can read files through gold.fs")
  tools.run("lua", { code = "bogus_global = 123" })
  eq(rawget(_G, "bogus_global"), nil, "lua tool: cannot leak into harness globals")
end

-- ---- fallback tools (prefer a rich impl, fall back to a built-in) ----------
do
  tools.register("_fb_primary",   { description = "p", input_schema = { type = "object" },
    run = function(a) return "PRIMARY:" .. tostring(a.x) end })
  tools.register("_fb_secondary", { description = "s", input_schema = { type = "object" },
    run = function(a) return "SECONDARY:" .. tostring(a.y) end })

  -- skips an absent target, uses the first one that is registered
  tools.register_fallback("_fb_logical", "d", { type = "object" }, { "_fb_missing", "_fb_primary" })
  eq(tools.run("_fb_logical", { x = 1 }), "PRIMARY:1", "fallback: skips missing, uses first available")

  -- adapt remaps args when the fallback's schema differs
  tools.register_fallback("_fb_logical2", "d", { type = "object" }, {
    { tool = "_fb_missing" },
    { tool = "_fb_secondary", adapt = function(a) return { y = a.q } end },
  })
  eq(tools.run("_fb_logical2", { q = 9 }), "SECONDARY:9", "fallback: adapt remaps args")

  -- a present target that answers tool_not_found is treated as unavailable
  tools.register("_fb_deadmcp", { description = "x", input_schema = { type = "object" },
    run = function() return "Tool error: [tool_not_found] server gone" end })
  tools.register_fallback("_fb_logical3", "d", { type = "object" }, { "_fb_deadmcp", "_fb_primary" })
  eq(tools.run("_fb_logical3", { x = 2 }), "PRIMARY:2",
     "fallback: skips a registered target that reports tool_not_found")

  -- nothing available -> a clear tool_not_found
  tools.register_fallback("_fb_none", "d", { type = "object" }, { "_fb_missing", "_fb_gone" })
  ok(tools.run("_fb_none", {}):find("tool_not_found"), "fallback: all-missing reports tool_not_found")
end

io.write(string.format("luatool: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
