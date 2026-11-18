-- tests/runflags.lua -- effort, context window and reply limit for an
-- unattended run (--headless / -p), from flags or the environment.
--
-- The first half drives lua/runflags.lua directly. The second runs the real
-- binary in --headless mode against a stand-in Messages API (a small Python
-- server) and reads the request it sent, so the whole path -- argv in C, the
-- setup in boot.lua, the request in api.lua -- is under test. That half needs
-- BOGGART_TEST_BIN (set by CMake), python3 and a POSIX shell, and says so when
-- it skips.
-- Run: boggart --eval tests/runflags.lua
local RF = require("runflags")
local json = require("json")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local function env(t) return function(k) return t[k] end end

-- ---- reading --------------------------------------------------------------------
do
  local s = assert(RF.read({}, env{}))
  ck(next(s) == nil, "nothing given: nothing set")

  s = assert(RF.read({ effort = "HIGH", context_window = "64000", max_output = "8000" }, env{}))
  eq(s.effort, "high", "flag effort, case-folded")
  eq(s.context_limit, 64000, "flag context window")
  eq(s.max_tokens, 8000, "flag reply limit")
  eq(math.type(s.context_limit), "integer", "a token count is an integer")

  s = assert(RF.read({}, env{ BOGGART_EFFORT = "low", BOGGART_CONTEXT_WINDOW = "32768",
                              BOGGART_MAX_OUTPUT = "2048" }))
  eq(s.effort, "low", "env effort")
  eq(s.context_limit, 32768, "env context window")
  eq(s.max_tokens, 2048, "env reply limit")

  s = assert(RF.read({ effort = "max" }, env{ BOGGART_EFFORT = "low", BOGGART_MAX_OUTPUT = "999" }))
  eq(s.effort, "max", "a flag beats the environment")
  eq(s.max_tokens, 999, "an unflagged setting still comes from the environment")

  for _, lvl in ipairs({ "minimal", "low", "medium", "high", "xhigh", "max" }) do
    ck(RF.read({ effort = lvl }, env{}) ~= nil, "effort level " .. lvl .. " is accepted")
  end
end

-- ---- validation -------------------------------------------------------------------
do
  local function refused(flags, envt, want)
    local s, err = RF.read(flags, env(envt or {}))
    ck(s == nil and type(err) == "string" and err:find(want, 1, true) ~= nil,
       string.format("refused naming %s (got %s)", want, tostring(err)))
  end
  refused({ effort = "turbo" }, nil, "--effort")
  refused({}, { BOGGART_EFFORT = "none" }, "BOGGART_EFFORT")
  refused({ context_window = "0" }, nil, "--context-window")
  refused({ context_window = "-5" }, nil, "--context-window")
  refused({ context_window = "64k" }, nil, "--context-window")
  refused({ max_output = "1.5" }, nil, "--max-output")
  refused({}, { BOGGART_MAX_OUTPUT = "lots" }, "BOGGART_MAX_OUTPUT")
  refused({}, { BOGGART_CONTEXT_WINDOW = "" .. "1e6" }, "BOGGART_CONTEXT_WINDOW")
end

-- ---- applying -----------------------------------------------------------------------
do
  local sess = { model = "m", messages = {} }
  ck(RF.setup(sess, { effort = "high", context_window = "50000", max_output = "4000" }, env{}) == sess,
     "setup returns the session")
  eq(sess.effort, "high", "effort set on the session")
  eq(sess.context_limit, 50000, "context window set on the session")
  eq(sess.max_tokens, 4000, "reply limit set on the session")

  local untouched = { model = "m", messages = {}, effort = "low" }
  RF.setup(untouched, {}, env{})
  eq(untouched.effort, "low", "nothing given leaves a session as it was")

  local s2, err = RF.setup({ messages = {} }, { context_window = "8000", max_output = "8000" }, env{})
  ck(s2 == nil and tostring(err):find("smaller", 1, true), "a reply limit that fills the window is refused")
end

-- ---- the real binary, headless -----------------------------------------------------
local bin = os.getenv("BOGGART_TEST_BIN")
local posix = package.config:sub(1, 1) == "/"
local function has_python()
  local p = io.popen("command -v python3 2>/dev/null"); if not p then return false end
  local s = p:read("l"); p:close(); return s ~= nil and s ~= ""
end
if not (bin and bin ~= "" and posix and has_python()) then
  io.write("runflags: end-to-end half skipped (needs BOGGART_TEST_BIN, python3, a POSIX shell)\n")
else
  local tmp = os.tmpname()
  os.remove(tmp)
  sys.mkdir_p(tmp)
  local log = tmp .. "/requests.jsonl"
  local srv = io.popen(string.format("python3 tests/fixtures/http/messages_server.py %q 60", log), "r")
  local port = tonumber(srv:read("l"))
  ck(port ~= nil, "stand-in server started")

  -- The model is deliberately NOT in the catalog: a catalogued model carries
  -- its provider's real endpoint, and this test must never leave the machine.
  -- A bare model id goes to ANTHROPIC_BASE_URL, the stand-in server; the
  -- claude- prefix keeps the Anthropic effort mapping (output_config).
  local function run(args, envs, stdin)
    local cmd = string.format(
      "cd %q && printf %%s %q | env BOGGART_HOME=%q ANTHROPIC_API_KEY=test-key "
      .. "ANTHROPIC_BASE_URL=http://127.0.0.1:%d %s %q --headless %s 2>&1; echo \"EXIT=$?\"",
      tmp, stdin or "", tmp .. "/home", port or 0, envs or "", bin, args)
    local p = io.popen(cmd, "r")
    local out = p:read("a"); p:close()
    return out, tonumber(out:match("EXIT=(%d+)%s*$"))
  end
  local function requests()
    local f = io.open(log, "r"); if not f then return {} end
    local out = {}
    for line in f:lines() do
      local ok, t = pcall(json.decode, line)
      if ok and type(t) == "table" and t.messages then out[#out + 1] = t end
    end
    f:close(); os.remove(log)
    return out
  end

  -- valid flags reach the request
  local out, code = run("--model claude-test-local --effort high --context-window 50000 --max-output 4000",
    nil, "say done")
  eq(code, 0, "headless run with flags exits 0 [" .. out:gsub("\n", " | "):sub(1, 300) .. "]")
  local reqs = requests()
  ck(#reqs >= 1, "the run sent a request (" .. #reqs .. ")")
  local turn = reqs[#reqs] or {}
  eq(turn.max_tokens, 4000, "--max-output is the request's max_tokens")
  eq(turn.output_config and turn.output_config.effort, "high", "--effort is the request's effort")

  -- the environment does the same
  out, code = run("--model claude-test-local",
    "BOGGART_EFFORT=low BOGGART_MAX_OUTPUT=3000 BOGGART_CONTEXT_WINDOW=40000", "say done")
  eq(code, 0, "headless run with environment settings exits 0")
  reqs = requests()
  turn = reqs[#reqs] or {}
  eq(turn.max_tokens, 3000, "BOGGART_MAX_OUTPUT is the request's max_tokens")
  eq(turn.output_config and turn.output_config.effort, "low", "BOGGART_EFFORT is the request's effort")

  -- the context window lowers the reply limit to the room left in it
  out, code = run("--model claude-test-local --context-window 20000", nil, string.rep("word ", 4000))
  eq(code, 0, "headless run with a small window exits 0")
  reqs = requests()
  turn = reqs[#reqs] or {}
  ck(type(turn.max_tokens) == "number" and turn.max_tokens < 16000,
     "--context-window 20000 lowers max_tokens below the 16000 default (got " .. tostring(turn.max_tokens) .. ")")

  -- a bad value stops the run before any request
  out, code = run("--model claude-test-local --effort turbo", nil, "say done")
  eq(code, 2, "a bad --effort exits 2")
  ck(out:find("--effort", 1, true) ~= nil, "and names the flag")
  out, code = run("--model claude-test-local", "BOGGART_CONTEXT_WINDOW=big", "say done")
  eq(code, 2, "a bad BOGGART_CONTEXT_WINDOW exits 2")
  ck(out:find("BOGGART_CONTEXT_WINDOW", 1, true) ~= nil, "and names the variable")
  eq(#requests(), 0, "no request was sent for a refused setting")

  -- --help documents them
  local hp = io.popen(string.format("%q --help 2>&1", bin), "r")
  local help = hp:read("a"); hp:close()
  for _, w in ipairs({ "--effort", "--context-window", "--max-output",
                       "BOGGART_EFFORT", "BOGGART_CONTEXT_WINDOW", "BOGGART_MAX_OUTPUT" }) do
    ck(help:find(w, 1, true) ~= nil, "--help mentions " .. w)
  end

  pcall(http.request, { url = "http://127.0.0.1:" .. tostring(port) .. "/quit", method = "GET", timeout = 5 })
  srv:close()
end

if fails == 0 then
  io.write("ok  runflags: --effort/--context-window/--max-output and their environment variables\n")
else
  io.write(string.format("FAIL runflags: %d check(s) failed\n", fails))
  os.exit(1)
end
