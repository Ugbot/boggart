-- tests/session_status.lua -- a root session is not left "running" after its turn.
--
-- The session's own agent checkpoints through thread.agent_opts, which saves
-- the row with status "running" -- right for a spawned child, whose run ends
-- with "done" or "error", but nothing ever ended the root's. Every REPL,
-- --headless and -p conversation that reached a checkpoint stayed "running"
-- and showed up in store.thread_list() as a live thread for good. The turn's
-- end now records how it ended: done, error, or killed (a cancelled turn).
--
-- The first half drives api.run_turn with run_on stubbed. The second runs the
-- real binary against the stand-in Messages API, through a finished turn and a
-- failed one, and reads the store afterwards. That half needs BOGGART_TEST_BIN
-- (set by CMake), python3 and a POSIX shell, and says so when it skips.
-- Run: BOGGART_TEST_BIN=$PWD/boggart boggart --eval tests/session_status.lua
local json = require("json")

bog.userdir = os.tmpname() .. "_boggart_session_status"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local function oneline(s) return (tostring(s or ""):gsub("\n", " | "):sub(1, 300)) end

local function status_of(id)
  local r = bog.db:query("SELECT status FROM sessions WHERE id=?", { id })
  return r[1] and r[1].status
end
local function listed_live(id)
  for _, r in ipairs(bog.store.thread_list(false)) do if r.id == id then return true end end
  return false
end

-- ---- api.run_turn ----------------------------------------------------------------------
do
  local real_run_on = bog.api.run_on
  local function stub(fail)
    return function(sess, text, _on_text, opts)
      sess.messages[#sess.messages + 1] = { role = "user", content = text }
      sess.messages[#sess.messages + 1] = { role = "assistant", content = { { type = "text", text = "ok" } } }
      if opts and opts.checkpoint then opts.checkpoint() end
      eq(status_of(sess.id), "running", "during the turn the row is running")
      if fail then error("scripted failure", 0) end
      return sess.messages[#sess.messages], "end_turn"
    end
  end

  bog.new_session()
  local S = bog.active_session()
  S.model = "claude-test-local"
  bog.api.run_on = stub(false)
  local ok, err = pcall(bog.api.run_turn, "a turn", nil)
  bog.api.run_on = real_run_on
  ck(ok, "run_turn ran (" .. tostring(err) .. ")")
  eq(status_of(S.id), "done", "a finished turn leaves the row done")
  ck(not listed_live(S.id), "and it is not listed as a live thread")

  bog.new_session()
  S = bog.active_session()
  bog.api.run_on = stub(true)
  ok, err = pcall(bog.api.run_turn, "a failing turn", nil)
  bog.api.run_on = real_run_on
  ck(not ok and tostring(err):find("scripted failure", 1, true), "a failed turn still raises its error")
  eq(status_of(S.id), "error", "a failed turn leaves the row error")
  ck(not listed_live(S.id), "and it is not listed as a live thread")
end

-- ---- the real binary -------------------------------------------------------------------
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
  -- Not in the catalog: this run must never leave the machine.
  local MODEL = "claude-test-local"

  local function run(mode, script)
    counter = counter + 1
    local dir = root .. "/s" .. counter
    sys.mkdir_p(dir .. "/work")
    write_file(dir .. "/script.json", json.encode(script))
    local srv = io.popen(string.format("python3 %q %q 60 %q",
      cwd .. "/tests/fixtures/http/messages_server.py", dir .. "/requests.jsonl", dir .. "/script.json"), "r")
    local port = tonumber(srv:read("l")) or 0
    local envs = string.format("env BOGGART_HOME=%q ANTHROPIC_API_KEY=test-key "
      .. "ANTHROPIC_BASE_URL=http://127.0.0.1:%d BOGGART_HEADLESS_POLICY=allow", dir .. "/home", port)
    local cmd
    if mode == "headless" then
      cmd = string.format("cd %q && printf %%s %q | %s %q --headless --model %s 2>&1; echo \"EXIT=$?\"",
        dir .. "/work", "go", envs, bin, MODEL)
    else
      cmd = string.format("cd %q && %s %q -p %q --model %s </dev/null 2>&1; echo \"EXIT=$?\"",
        dir .. "/work", envs, bin, "go", MODEL)
    end
    local p = io.popen(cmd, "r")
    local out = p:read("a"); p:close()
    pcall(http.request, { url = "http://127.0.0.1:" .. tostring(port) .. "/quit", method = "GET", timeout = 5 })
    srv:close()

    local probe = dir .. "/probe.lua"
    write_file(probe, [[
      bog.store.open()
      local json = require("json")
      local rows = bog.db:query("SELECT id, status FROM sessions ORDER BY id")
      local live = bog.store.thread_list(false)
      io.write(json.encode({ rows = rows, live = #live }), "\n")
      return 0
    ]])
    local pp = io.popen(string.format("cd %q && env BOGGART_HOME=%q %q --eval %q 2>&1",
      dir .. "/work", dir .. "/home", bin, probe), "r")
    local raw = pp:read("a"); pp:close()
    local ok, got = pcall(json.decode, raw:match("(%b{})%s*$") or "")
    ck(ok and type(got) == "table", "read the store [" .. oneline(raw) .. "]")
    return out, (ok and type(got) == "table") and got or { rows = {} }
  end

  local TOOL = { { tool_use = { id = "toolu_1", name = "bash", input = { command = "echo hi" } } },
                 { text = "all done" } }
  local FAIL = { { tool_use = { id = "toolu_1", name = "bash", input = { command = "echo hi" } } },
                 { status = 400, message = "scripted failure" } }
  for _, mode in ipairs({ "headless", "-p" }) do
    local out, st = run(mode, TOOL)
    ck(out:match("EXIT=0%s*$"), mode .. ": the turn finished [" .. oneline(out) .. "]")
    eq(#st.rows, 1, mode .. ": one session row")
    eq(st.rows[1] and st.rows[1].status, "done", mode .. ": a finished turn leaves the root session done")
    eq(st.live, 0, mode .. ": no live thread is listed after the run")

    out, st = run(mode, FAIL)
    ck(out:match("EXIT=1%s*$"), mode .. ": the failed turn exits 1 [" .. oneline(out) .. "]")
    eq(st.rows[1] and st.rows[1].status, "error", mode .. ": a failed turn leaves the root session error")
    eq(st.live, 0, mode .. ": no live thread is listed after the failed run")
  end
else
  io.write("session_status: binary half skipped (needs BOGGART_TEST_BIN, python3, a POSIX shell)\n")
end

if fails == 0 then
  io.write("ok  session_status: a root session ends its turn done, error or killed, not running\n")
else
  io.write(string.format("FAIL session_status: %d check(s) failed\n", fails))
  os.exit(1)
end
