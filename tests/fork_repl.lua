-- tests/fork_repl.lua -- the root agent of an interactive or one-shot run can fork.
--
-- run_one_turn (the REPL, --headless, -p) captured the scheduler id of the
-- root's turn as `S.id or 1` before the conversation had a row, so the turn
-- ran as actor 1 while its session got some other id. spawn{ fork = true }
-- looks the parent up by the running actor's id, found nothing, and failed
-- with "no live conversation to fork" -- unless the new session happened to be
-- row 1, which is why a fresh data directory hid it. run_one_turn now creates
-- the row first (headless-fixes), so the actor id and the session id agree.
--
-- This runs the binary with -p (the same turn driver as the REPL) against the
-- stand-in Messages API, in a data directory that already has a session, so
-- the forking conversation is not row 1. The model forks once; the child's
-- first request must be the parent's prompt and tools plus the fork's turn.
-- Needs BOGGART_TEST_BIN (set by CMake), python3 and a POSIX shell, and says
-- so when it skips.
-- Run: BOGGART_TEST_BIN=$PWD/boggart boggart --eval tests/fork_repl.lua
local json = require("json")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local function oneline(s) return (tostring(s or ""):gsub("\n", " | "):sub(1, 400)) end

local bin = os.getenv("BOGGART_TEST_BIN")
local posix = package.config:sub(1, 1) == "/"
local function has_python()
  local p = io.popen("command -v python3 2>/dev/null"); if not p then return false end
  local s = p:read("l"); p:close(); return s ~= nil and s ~= ""
end
if not (bin and bin ~= "" and posix and has_python()) then
  io.write("fork_repl: skipped (needs BOGGART_TEST_BIN, python3, a POSIX shell)\n")
  return 0
end

local root = os.tmpname()
os.remove(root)
sys.mkdir_p(root .. "/work")
local cwd = (io.popen("pwd"):read("l"))
local home = root .. "/home"
local function write_file(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
-- Not in the catalog: this run must never leave the machine.
local MODEL = "claude-test-local"

local function oneshot(script, task)
  local tag = tostring(os.time()) .. tostring(math.random(1e6))
  local log, sfile = root .. "/req-" .. tag .. ".jsonl", root .. "/script-" .. tag .. ".json"
  write_file(sfile, json.encode(script))
  local srv = io.popen(string.format("python3 %q %q 60 %q",
    cwd .. "/tests/fixtures/http/messages_server.py", log, sfile), "r")
  local port = tonumber(srv:read("l")) or 0
  local p = io.popen(string.format("cd %q && env BOGGART_HOME=%q ANTHROPIC_API_KEY=test-key "
    .. "ANTHROPIC_BASE_URL=http://127.0.0.1:%d BOGGART_HEADLESS_POLICY=allow "
    .. "%q -p %q --model %s </dev/null 2>&1; echo \"EXIT=$?\"",
    root .. "/work", home, port, bin, task, MODEL), "r")
  local out = p:read("a"); p:close()
  pcall(http.request, { url = "http://127.0.0.1:" .. tostring(port) .. "/quit", method = "GET", timeout = 5 })
  srv:close()
  local reqs = {}
  local f = io.open(log, "r")
  if f then
    for line in f:lines() do
      local ok, t = pcall(json.decode, line)
      if ok and type(t) == "table" and t.messages then reqs[#reqs + 1] = t end
    end
    f:close()
  end
  return out, reqs
end

-- An earlier conversation, so the one that forks is not session 1.
local out = oneshot({ { text = "first" } }, "an earlier conversation")
ck(out:match("EXIT=0%s*$"), "the earlier conversation ran [" .. oneline(out) .. "]")

local reqs
out, reqs = oneshot({
  { tool_use = { id = "toolu_f1", name = "spawn", input = { fork = true, task = "check the README" } } },
}, "fork a helper")
ck(out:match("EXIT=0%s*$"), "the forking turn finished [" .. oneline(out) .. "]")
ck(not out:find("no live conversation", 1, true), "the fork found its parent [" .. oneline(out) .. "]")

local function text_of(content)
  if type(content) == "string" then return content end
  local t = {}
  for _, b in ipairs(content or {}) do
    if b.type == "text" then t[#t + 1] = b.text or "" end
    if b.type == "tool_result" then
      t[#t + 1] = type(b.content) == "string" and b.content or json.encode(b.content)
    end
  end
  return table.concat(t, "\n")
end
local function names(tools)
  local t = {}
  for _, x in ipairs(tools or {}) do t[#t + 1] = x.name end
  return table.concat(t, ",")
end

local parent = reqs[1] or {}
local child, parent_next
for i = 2, #reqs do
  local last = reqs[i].messages[#reqs[i].messages] or {}
  local txt = text_of(last.content)
  if txt:find("You are a forked sub-agent", 1, true) then child = reqs[i]
  elseif type(last.content) == "table" and last.content[1]
         and last.content[1].tool_use_id == "toolu_f1" then parent_next = { req = reqs[i], text = txt } end
end
ck(parent_next ~= nil, "the parent got the spawn's result [" .. #reqs .. " requests]")
parent_next = parent_next or { text = "" }
ck(parent_next.text:find("spawned", 1, true) ~= nil,
   "the spawn succeeded (the parent saw: " .. oneline(parent_next.text) .. ")")
ck(child ~= nil, "the forked child sent a request")
child = child or {}
eq(json.encode(child.system), json.encode(parent.system), "the child's system prompt is the parent's")
eq(names(child.tools), names(parent.tools), "the child's tools are the parent's")
ck(#(parent.tools or {}) > 0, "the parent was offered tools")
eq(json.encode((child.messages or {})[1]), json.encode((parent.messages or {})[1]),
   "the child's conversation starts with the parent's")

if fails == 0 then
  io.write("ok  fork_repl: the root agent of a -p/REPL turn forks with its own prompt and tools\n")
else
  io.write(string.format("FAIL fork_repl: %d check(s) failed\n", fails))
  os.exit(1)
end
