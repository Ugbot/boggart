-- tests/no_color.lua -- colour only on a terminal, and never under NO_COLOR.
--
-- Tool markers ("» bash: ...") and turn errors were written with ANSI colour
-- codes whatever stdout was, so a headless or -p run piped into a file or a
-- harness carried escape sequences, even with NO_COLOR=1 (https://no-color.org).
-- Colour is now decided once per stream: on only when that stream is a
-- terminal and NO_COLOR is unset or empty.
--
-- The first half checks the decision (util.color_ok) with stubs. The second
-- runs the real binary against the stand-in Messages API with stdout piped,
-- through a tool call and through a failed turn, and looks for any escape
-- byte. Needs BOGGART_TEST_BIN (set by CMake), python3 and a POSIX shell, and
-- says so when it skips.
-- Run: BOGGART_TEST_BIN=$PWD/boggart boggart --eval tests/no_color.lua
local json = require("json")
local util = require("util")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local function shown(s) return (tostring(s or ""):gsub("\27", "\\e"):gsub("\n", " | "):sub(1, 400)) end

-- ---- the decision -------------------------------------------------------------------
local color_ok = util.color_ok or function() return "missing" end
do
  local function env(t) return function(k) return t[k] end end
  local tty = function() return "tty" end
  local pipe = function() return "pipe" end
  eq(color_ok(1, env{}, tty), true, "a terminal with NO_COLOR unset: colour")
  eq(color_ok(1, env{ NO_COLOR = "1" }, tty), false, "NO_COLOR=1: no colour")
  eq(color_ok(1, env{ NO_COLOR = "anything" }, tty), false, "NO_COLOR with any value: no colour")
  eq(color_ok(1, env{ NO_COLOR = "" }, tty), true, "an empty NO_COLOR is unset (no-color.org)")
  eq(color_ok(1, env{}, pipe), false, "a pipe: no colour")
  eq(color_ok(2, env{}, function(fd) return fd == 2 and "tty" or "pipe" end), true,
     "decided per stream")
end

-- ---- the real binary ----------------------------------------------------------------
local bin = os.getenv("BOGGART_TEST_BIN")
local posix = package.config:sub(1, 1) == "/"
local function has_python()
  local p = io.popen("command -v python3 2>/dev/null"); if not p then return false end
  local s = p:read("l"); p:close(); return s ~= nil and s ~= ""
end
if bin and bin ~= "" and posix and has_python() then
  local root = os.tmpname()
  os.remove(root)
  sys.mkdir_p(root)
  local cwd = (io.popen("pwd"):read("l"))
  local counter = 0
  local function write_file(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
  local function read_file(path)
    local f = io.open(path, "r"); if not f then return "" end
    local s = f:read("a"); f:close(); return s
  end
  -- Not in the catalog: this run must never leave the machine.
  local MODEL = "claude-test-local"

  -- Run one turn against a stand-in playing `script`; stdout and stderr are
  -- captured to separate files, both pipes.
  local function run(mode, script, extra_env)
    counter = counter + 1
    local dir = root .. "/s" .. counter
    sys.mkdir_p(dir .. "/work")
    write_file(dir .. "/script.json", json.encode(script))
    local srv = io.popen(string.format("python3 %q %q 60 %q",
      cwd .. "/tests/fixtures/http/messages_server.py", dir .. "/requests.jsonl", dir .. "/script.json"), "r")
    local port = tonumber(srv:read("l")) or 0
    local envs = string.format("env BOGGART_HOME=%q ANTHROPIC_API_KEY=test-key "
      .. "ANTHROPIC_BASE_URL=http://127.0.0.1:%d BOGGART_HEADLESS_POLICY=allow %s",
      dir .. "/home", port, extra_env or "")
    local cmd
    if mode == "headless" then
      cmd = string.format("cd %q && printf %%s %q | %s %q --headless --model %s >%q 2>%q; echo $?",
        dir .. "/work", "go", envs, bin, MODEL, dir .. "/out", dir .. "/err")
    else
      cmd = string.format("cd %q && %s %q -p %q --model %s </dev/null >%q 2>%q; echo $?",
        dir .. "/work", envs, bin, "go", MODEL, dir .. "/out", dir .. "/err")
    end
    local p = io.popen(cmd, "r")
    local code = tonumber(p:read("l")); p:close()
    pcall(http.request, { url = "http://127.0.0.1:" .. tostring(port) .. "/quit", method = "GET", timeout = 5 })
    srv:close()
    return code, read_file(dir .. "/out"), read_file(dir .. "/err")
  end

  local TOOL = { { tool_use = { id = "toolu_1", name = "bash", input = { command = "echo hi" } } },
                 { text = "all done" } }
  local FAIL = { { status = 400, message = "scripted failure" } }

  for _, mode in ipairs({ "headless", "-p" }) do
    for _, nc in ipairs({ "NO_COLOR=1", "" }) do
      local label = mode .. (nc ~= "" and " NO_COLOR=1" or " piped")
      local code, out, err = run(mode, TOOL, nc)
      eq(code, 0, label .. ": the tool turn finished [" .. shown(out .. err) .. "]")
      ck(out:find("bash: echo hi", 1, true) ~= nil, label .. ": the tool marker is on stdout [" .. shown(out) .. "]")
      ck(not out:find("\27", 1, true), label .. ": no escape codes on stdout [" .. shown(out) .. "]")
      ck(not err:find("\27", 1, true), label .. ": no escape codes on stderr [" .. shown(err) .. "]")

      code, out, err = run(mode, FAIL, nc)
      eq(code, 1, label .. ": a failed turn exits 1")
      ck(out:find("scripted failure", 1, true) ~= nil, label .. ": the error is on stdout [" .. shown(out) .. "]")
      ck(not out:find("\27", 1, true), label .. ": no escape codes on a failed turn's stdout [" .. shown(out) .. "]")
      ck(not err:find("\27", 1, true), label .. ": no escape codes on a failed turn's stderr [" .. shown(err) .. "]")
      if mode == "-p" and nc ~= "" then io.write("  failed -p turn, stdout: ", shown(out), "\n") end
    end
  end
else
  io.write("no_color: binary half skipped (needs BOGGART_TEST_BIN, python3, a POSIX shell)\n")
end

if fails == 0 then
  io.write("ok  no_color: colour only on a terminal, never under NO_COLOR\n")
else
  io.write(string.format("FAIL no_color: %d check(s) failed\n", fails))
  os.exit(1)
end
