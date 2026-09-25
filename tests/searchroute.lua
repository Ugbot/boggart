-- searchroute.lua -- which bash searches LLM Station answers, and that nothing
-- else changes meaning. translate() is pure; dispatch runs against a stubbed
-- stationlink, so no daemon (and no ZMQ build) is needed.
local sr = require("searchroute")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local CWD = "/w"
local function T(cmd) return sr.translate(cmd, CWD) end
local function routes(cmd, tool, pattern, path, name)
  local t, why = T(cmd)
  ok(t ~= nil, name .. " routes (" .. tostring(why) .. ")")
  if not t then return end
  eq(t.tool, tool, name .. ": tool")
  if pattern then eq(t.params.pattern, pattern, name .. ": pattern") end
  if path then eq(t.params.path, path, name .. ": path") end
  return t
end
local function stays(cmd, name)
  local t = T(cmd)
  ok(t == nil, name .. " stays in the shell")
end

-- ---- grep forms that route -----------------------------------------------------
routes("grep -rn foo_bar lua/", "grep_search", "foo_bar", "/w/lua/", "grep -rn ident dir")
routes("grep -rn 'M.register' .", "grep_search", "M.register", "/w", "BRE dot is the same in ECMAScript")
routes("grep -rnI -F 'a.b(c)' src", "grep_search", "a\\.b\\(c\\)", "/w/src", "-F escapes every metachar")
routes("grep -rnE 'foo(bar|baz)+' src", "grep_search", "foo(bar|baz)+", "/w/src", "-E passes ERE through")
routes("grep -rnw run lua", "grep_search", "\\brun\\b", "/w/lua", "-w wraps word boundaries")
routes("grep -rn -e -dash lua", "grep_search", "-dash", "/w/lua", "-e takes a leading-dash pattern")
routes("grep -rn foo", "grep_search", "foo", "/w", "recursive with no path searches .")
routes("grep -n foo lua/tools.lua", "grep_search", "foo", "/w/lua/tools.lua", "a single file needs no -r")
routes("grep -rn foo /abs/path", "grep_search", "foo", "/abs/path", "absolute paths pass through")
routes("cd /repo && grep -rn foo src", "grep_search", "foo", "/repo/src", "leading cd rebases the path")
local t = routes("grep -rn foo --include='*.lua' lua", "grep_search", "foo", "/w/lua", "--include")
eq(t and t.params.glob, "*.lua", "--include becomes the glob")
t = routes("grep -rn foo lua | head -n 20", "grep_search", "foo", nil, "| head -n N")
eq(t and t.params.max_results, 20, "head -n caps results")
t = routes("grep -rn foo lua | head -5", "grep_search", nil, nil, "| head -N")
eq(t and t.params.max_results, 5, "head -N caps results")
t = routes("grep -rn -C 2 foo lua", "grep_search", "foo", nil, "-C context")
eq(t and t.params.context_lines, 2, "-C becomes context_lines")
routes('grep -rn "say \\"hi\\"" lua', "grep_search", 'say "hi"', nil, "escaped double quotes")

-- ---- rg --------------------------------------------------------------------------
routes("rg foo", "grep_search", "foo", "/w", "rg defaults to recursive .")
t = routes("rg -n -g '*.c' 'lua_[a-z]+' src", "grep_search", "lua_[a-z]+", "/w/src", "rg regex + glob")
eq(t and t.params.glob, "*.c", "rg -g becomes the glob")
routes("rg -F 'x.y' .", "grep_search", "x\\.y", nil, "rg -F")

-- ---- find ------------------------------------------------------------------------
t = routes("find lua -name '*.lua'", "glob_search", "**/*.lua", "/w/lua", "find -name")
routes("find . -type f -name 'test_*.c'", "glob_search", "**/test_*.c", "/w", "find -type f -name")

-- ---- forms that must stay in the shell -------------------------------------------
stays("grep -rni foo lua", "case-insensitive (station cannot fold case)")
stays("grep -rnv foo lua", "inverted match")
stays("grep -rl foo lua", "files-only mode")
stays("grep -rc foo lua", "count mode")
stays("grep -rn foo lua src", "several paths")
stays("grep -rn foo lua/*.lua", "an unquoted shell glob")
stays("grep -rn 'a\\|b' lua", "BRE alternation")
stays("grep -rn 'x+' lua", "BRE literal plus (means something else in ECMAScript)")
stays("grep -rn '[[:alpha:]]' lua", "POSIX class")
stays("grep foo", "grep with no file reads stdin")
stays("grep -rn foo lua | wc -l", "a pipe into anything but head")
stays("grep -rn foo lua > out.txt", "a redirect")
stays("grep -rn $PAT lua", "a variable expansion")
stays("grep -rn foo lua; ls", "sequencing")
stays("git grep foo", "git grep is not grep")
stays("find . -name '*.c' -o -name '*.h'", "find with -o")
stays("find . -newer x", "find without -name")
stays("ls lua", "not a search")
stays("rg -g '!vendor' foo", "rg negative glob")
stays("grep -rn foo lua | head -n 5 | sort", "a pipeline after head")

-- ---- dispatch: routed when live, native otherwise, never a failed answer ---------
do
  local calls = {}
  local live, reply = true, "lua/a.lua:1: foo\nlua/b.lua:2: foo\nlua/c.lua:3: foo"
  package.loaded.stationlink = {
    active = function() return live end,
    call = function(tool, params) calls[#calls + 1] = { tool = tool, params = params }
      if reply then return reply end
      return nil, "boom" end,
  }
  local out = sr.run("grep -rn foo lua", CWD)
  ok(out and out:find("answered by llm%-station grep_search"), "live link: answered by station")
  eq(calls[1] and calls[1].tool, "grep_search", "the station tool called")
  eq(calls[1] and calls[1].params.path, "/w/lua", "with an absolute path")
  out = sr.run("find lua -name '*.lua' | head -2", CWD)
  local n = 0; for _ in (out or ""):gmatch("\n") do n = n + 1 end
  eq(n, 2, "a head on glob_search is applied to the reply (header + 2 lines)")
  eq(sr.run("grep -rni foo lua", CWD), nil, "an unroutable form is left to the shell")
  reply = nil
  eq(sr.run("grep -rn foo lua", CWD), nil, "a daemon failure is not an answer: shell runs it")
  ok(sr.stats.failed >= 1, "and the fallback is counted")
  reply = "x"; live = false
  local before = #calls
  eq(sr.run("grep -rn foo lua", CWD), nil, "link down: shell runs it")
  eq(#calls, before, "...without touching the daemon")
  live = true
  local saved = os.getenv
  os.getenv = function(k) if k == "BOGGART_STATION_SEARCH" then return "0" end return saved(k) end
  eq(sr.run("grep -rn foo lua", CWD), nil, "BOGGART_STATION_SEARCH=0 switches routing off")
  os.getenv = saved
  package.loaded.stationlink = nil
end

-- ---- the real stationlink in a build without ZMQ: honest refusals ---------------
do
  local stn = require("stationlink")
  local s = stn.status()
  ok(type(s) == "table" and s.up == false, "status() works with no daemon")
  if not s.enabled then
    local okk, why = stn.start()
    ok(okk == nil and tostring(why):find("BOGGART_STATION=ON", 1, true),
       "start() without the ZMQ client says how to get it")
    eq(stn.active(), false, "active() is false and does not raise")
  end
end

io.write(string.format("searchroute: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
