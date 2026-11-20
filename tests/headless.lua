-- tests/headless.lua -- an unattended run (--headless, -p) end to end.
--
-- Runs the real binary against a stand-in Messages API
-- (tests/fixtures/http/messages_server.py) that plays a script: a tool call,
-- then a text reply. So the whole path is under test -- argv in C, the turn
-- driver in boot.lua, the permission gate, the store.
--
--   * gated tools in an unattended run resolve through BOGGART_HEADLESS_POLICY
--     (allow runs them; unset refuses them, and the model is told so) rather
--     than through a prompt read from a stdin nobody is typing at
--   * a headless turn killed part way (a harness's time limit) leaves its
--     transcript in the store up to the last checkpoint: the task, the tool
--     call and the tool's result
--
-- Needs BOGGART_TEST_BIN (set by CMake), python3 and a POSIX shell, and says
-- so when it skips.
-- Run: BOGGART_TEST_BIN=$PWD/boggart boggart --eval tests/headless.lua
local json = require("json")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local function oneline(s) return (tostring(s or ""):gsub("\n", " | "):sub(1, 300)) end

local bin = os.getenv("BOGGART_TEST_BIN")
local posix = package.config:sub(1, 1) == "/"
local function has_python()
  local p = io.popen("command -v python3 2>/dev/null"); if not p then return false end
  local s = p:read("l"); p:close(); return s ~= nil and s ~= ""
end
if not (bin and bin ~= "" and posix and has_python()) then
  io.write("headless: skipped (needs BOGGART_TEST_BIN, python3, a POSIX shell)\n")
  return 0
end

local root = os.tmpname()
os.remove(root)
sys.mkdir_p(root)
local cwd = (io.popen("pwd"):read("l"))
local counter = 0

local function write_file(path, s)
  local f = assert(io.open(path, "w")); f:write(s); f:close()
end
local function read_file(path)
  local f = io.open(path, "r"); if not f then return nil end
  local s = f:read("a"); f:close(); return s
end

-- A fresh scratch directory, its own BOGGART_HOME, and a stand-in server
-- playing `script`. Returns a table with the paths, the port and stop().
local function scenario(script)
  counter = counter + 1
  local dir = root .. "/s" .. counter
  sys.mkdir_p(dir .. "/work")
  local log, sfile = dir .. "/requests.jsonl", dir .. "/script.json"
  write_file(sfile, json.encode(script))
  local srv = io.popen(string.format("python3 %q %q 60 %q",
    cwd .. "/tests/fixtures/http/messages_server.py", log, sfile), "r")
  local port = tonumber(srv:read("l"))
  ck(port ~= nil, "stand-in server started")
  local sc = { dir = dir, work = dir .. "/work", home = dir .. "/home", log = log, port = port or 0 }
  function sc.env(extra)
    return string.format("env BOGGART_HOME=%q ANTHROPIC_API_KEY=test-key "
      .. "ANTHROPIC_BASE_URL=http://127.0.0.1:%d %s", sc.home, sc.port, extra or "")
  end
  function sc.requests()
    local f = io.open(log, "r"); if not f then return {} end
    local out = {}
    for line in f:lines() do
      local ok, t = pcall(json.decode, line)
      if ok and type(t) == "table" and t.messages then out[#out + 1] = t end
    end
    f:close()
    return out
  end
  function sc.stop()
    pcall(http.request, { url = "http://127.0.0.1:" .. tostring(sc.port) .. "/quit",
                          method = "GET", timeout = 5 })
    srv:close()
  end
  return sc
end

-- The model is deliberately NOT in the catalog: a catalogued model carries its
-- provider's real endpoint, and this test must never leave the machine.
local MODEL = "claude-test-local"

local function headless(sc, envs, task)
  local p = io.popen(string.format(
    "cd %q && printf %%s %q | %s %q --headless --model %s 2>&1; echo \"EXIT=$?\"",
    sc.work, task, sc.env(envs), bin, MODEL), "r")
  local out = p:read("a"); p:close()
  return out, tonumber(out:match("EXIT=(%d+)%s*$"))
end
local function oneshot(sc, envs, task)
  local p = io.popen(string.format(
    "cd %q && %s %q -p %q --model %s </dev/null 2>&1; echo \"EXIT=$?\"",
    sc.work, sc.env(envs), bin, task, MODEL), "r")
  local out = p:read("a"); p:close()
  return out, tonumber(out:match("EXIT=(%d+)%s*$"))
end

-- The tool_result the second request carried back to the model for `id`.
local function tool_result(req, id)
  for _, m in ipairs(req and req.messages or {}) do
    if type(m.content) == "table" then
      for _, b in ipairs(m.content) do
        if b.type == "tool_result" and b.tool_use_id == id then
          local c = b.content
          if type(c) == "table" then
            local t = {}
            for _, x in ipairs(c) do t[#t + 1] = x.text or "" end
            c = table.concat(t)
          end
          return tostring(c), b
        end
      end
    end
  end
end

-- ---- gated tools follow BOGGART_HEADLESS_POLICY ----------------------------------
local WRITE = { { tool_use = { id = "toolu_w1", name = "write",
                               input = { path = "out.txt", content = "hello from the model\n" } } },
                { text = "wrote it" } }

for _, mode in ipairs({ { "headless", headless }, { "-p", oneshot } }) do
  local name, runner = mode[1], mode[2]

  -- allow: the write runs
  local sc = scenario(WRITE)
  local out, code = runner(sc, "BOGGART_HEADLESS_POLICY=allow", "write the file")
  eq(code, 0, name .. " with policy allow exits 0 [" .. oneline(out) .. "]")
  eq(read_file(sc.work .. "/out.txt"), "hello from the model\n",
     name .. " with policy allow: the gated write ran")
  local reqs = sc.requests()
  eq(#reqs, 2, name .. ": the tool result went back to the model")
  local res = tool_result(reqs[2], "toolu_w1")
  ck(res ~= nil and not res:find("permission_error", 1, true),
     name .. " allow: the model saw the write succeed (" .. oneline(res) .. ")")
  sc.stop()

  -- unset: fail closed, and the model is told
  sc = scenario(WRITE)
  out, code = runner(sc, "", "write the file")
  eq(code, 0, name .. " with no policy still finishes the turn [" .. oneline(out) .. "]")
  eq(read_file(sc.work .. "/out.txt"), nil, name .. " with no policy: the gated write was refused")
  reqs = sc.requests()
  eq(#reqs, 2, name .. " no policy: the refusal went back to the model")
  res = tool_result(reqs[2], "toolu_w1")
  ck(res ~= nil and res:find("permission_error", 1, true) ~= nil,
     name .. " no policy: the model's tool result is the permission refusal (" .. oneline(res) .. ")")
  ck(not out:find("[y]es", 1, true), name .. " no policy: nobody was asked on stdin")
  sc.stop()
end

-- ---- a killed turn leaves its transcript ------------------------------------------
do
  -- The model calls bash, then never answers the next request. The run is
  -- killed while it waits, the way a benchmark harness ends a run that is out
  -- of time; the checkpoints taken before that must already be in the store.
  local sc = scenario({ { tool_use = { id = "toolu_b1", name = "bash", input = { command = "echo hi" } } },
                        { hang = true } })
  local p = io.popen(string.format(
    "cd %q && printf %%s %q | %s %q --headless --model %s >%q 2>&1 & echo $!",
    sc.work, "say hi with bash", sc.env("BOGGART_HEADLESS_POLICY=allow"), bin, MODEL,
    sc.dir .. "/out.txt"), "r")
  local pid = tonumber(p:read("l")); p:close()
  ck(pid ~= nil, "headless run started in the background")
  -- the second request goes out only after the tool result is checkpointed
  local waited = 0
  while #sc.requests() < 2 and waited < 100 do os.execute("sleep 0.1"); waited = waited + 1 end
  eq(#sc.requests(), 2, "the run sent the tool result back before it was killed")
  os.execute("sleep 0.3")
  os.execute(string.format("kill -TERM %d 2>/dev/null; sleep 0.5; kill -KILL %d 2>/dev/null", pid, pid))
  sc.stop()

  local probe = sc.dir .. "/probe.lua"
  write_file(probe, [[
    bog.store.open()
    local json = require("json")
    local list = bog.store.sess_list(10) or {}
    local s = list[1] and bog.store.sess_load(list[1].id)
    io.write(json.encode({ count = #list, messages = s and s.messages or json.null }), "\n")
    return 0
  ]])
  local pp = io.popen(string.format("cd %q && env BOGGART_HOME=%q %q --eval %q 2>&1",
    sc.work, sc.home, bin, probe), "r")
  local raw = pp:read("a"); pp:close()
  local ok, got = pcall(json.decode, raw:match("(%b{})%s*$") or "")
  ck(ok and type(got) == "table", "read the store after the kill [" .. oneline(raw) .. "]")
  got = ok and type(got) == "table" and got or {}
  eq(got.count, 1, "the killed run left one session")
  local msgs = type(got.messages) == "table" and got.messages or {}
  local has_task, has_call, has_result = false, false, false
  for _, m in ipairs(msgs) do
    if m.role == "user" and type(m.content) == "string" and m.content:find("say hi with bash", 1, true) then
      has_task = true
    end
    if type(m.content) == "table" then
      for _, b in ipairs(m.content) do
        if m.role == "user" and b.type == "text" and tostring(b.text):find("say hi with bash", 1, true) then
          has_task = true
        end
        if b.type == "tool_use" and b.id == "toolu_b1" and b.name == "bash" then has_call = true end
        if b.type == "tool_result" and b.tool_use_id == "toolu_b1"
           and json.encode(b.content):find("hi", 1, true) then has_result = true end
      end
    end
  end
  local shown = oneline(json.encode(msgs))
  ck(has_task, "the stored transcript holds the task (" .. shown .. ")")
  ck(has_call, "the stored transcript holds the tool call")
  ck(has_result, "the stored transcript holds the tool result")
end

if fails == 0 then
  io.write("ok  headless: unattended runs gate tools by BOGGART_HEADLESS_POLICY; a killed turn keeps its transcript\n")
else
  io.write(string.format("FAIL headless: %d check(s) failed\n", fails))
  os.exit(1)
end
