-- tests/effort_plumbing.lua -- a requested reasoning effort reaches the request,
-- and `none` never reaches it as a level.
--
--   * workers.agents{ effort = ... } passed the level as a run option, and the
--     turn loop read effort only from the session, so worker turns went out
--     with no effort at all. run_on now honours opts.effort for the call (the
--     same precedence as opts.model: the call, then the agent).
--   * the spawn tool offers effort `none`. It means "send no effort setting"
--     (as `/effort none` does), not a level: a child spawned with it sends no
--     reasoning_effort and no output_config, rather than "none" on the wire,
--     and does not fall back to the parent's or the default level either.
--
-- The worker half runs real worker threads against the stand-in Messages API
-- (tests/fixtures/http/messages_server.py), so it needs python3 and a POSIX
-- shell, and says so when it skips.
-- Run: boggart --eval tests/effort_plumbing.lua
local json = require("json")

bog.userdir = os.tmpname() .. "_boggart_effort_plumbing"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()
require("catalog").seed_if_empty()
local thread = require("thread")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

-- Not in the catalog, and on no real endpoint: nothing here leaves the machine.
local MODEL = "claude-test-local"

local function sent_by(sess, opts)
  local body
  opts = opts or {}
  opts.stream = function(b)
    body = b
    return { role = "assistant", content = { { type = "text", text = "ok" } },
             usage = { input_tokens = 10, output_tokens = 1 } }, "end_turn"
  end
  opts.system = function() return "" end
  opts.tools = function() return {} end
  bog.api.run_on(sess, "hello", nil, opts)
  return body or {}
end

-- ---- run_on: the call's effort, then the session's --------------------------------
eq(sent_by({ model = MODEL, messages = {} }, { effort = "high" }).reasoning_effort, "high",
   "a run option's effort reaches the request")
eq(sent_by({ model = MODEL, messages = {}, effort = "low" }, { effort = "high" }).reasoning_effort, "high",
   "the call's effort beats the session's")
eq(sent_by({ model = MODEL, messages = {}, effort = "low" }, {}).reasoning_effort, "low",
   "no call effort: the session's")
eq(sent_by({ model = MODEL, messages = {} }, { effort = "none" }).reasoning_effort, nil,
   "effort none on the call: nothing sent")

-- ---- spawn effort none ----------------------------------------------------------------
local P = bog.session
P.model, P.route, P.effort = MODEL, nil, "high"
local child = thread.new_agent{ task = "x", effort = "none" }
eq(child.session.effort, "none", "a none child does not take the parent's or the default level")
local body = sent_by(child.session)
eq(body.reasoning_effort, nil, "a none child sends no reasoning_effort")
local wire = bog.api._to_anthropic_body(body)
eq(wire.output_config, nil, "and no output_config on the Anthropic wire")
local owire = bog.api._to_openai_body(body)
eq(owire.reasoning_effort, nil, "and no reasoning_effort on the OpenAI wire")
local grand = thread.new_agent{ task = "x", parent_id = child.id }
eq(sent_by(grand.session).reasoning_effort, nil, "its children inherit the opt-out")
P.effort = nil

local spawn_desc = json.encode(require("tools_swarm").defs.spawn.input_schema.properties.effort)
ck(spawn_desc:find("none sends no effort setting", 1, true) ~= nil,
   "the spawn tool says what none means")

-- ---- workers.agents: the level reaches the wire ---------------------------------------
local posix = package.config:sub(1, 1) == "/"
local function has_python()
  local p = io.popen("command -v python3 2>/dev/null"); if not p then return false end
  local s = p:read("l"); p:close(); return s ~= nil and s ~= ""
end
if posix and has_python() then
  local dir = os.tmpname()
  os.remove(dir)
  sys.mkdir_p(dir)
  local cwd = (io.popen("pwd"):read("l"))
  local log = dir .. "/requests.jsonl"
  local srv = io.popen(string.format("python3 %q %q 60",
    cwd .. "/tests/fixtures/http/messages_server.py", log), "r")
  local port = tonumber(srv:read("l"))
  ck(port ~= nil, "stand-in server started")
  local had_base = auth.base_url()
  auth.set("base_url", "http://127.0.0.1:" .. tostring(port))
  local texts, errs = require("workers").agents({ "one", "two" },
    { model = MODEL, effort = "high", slots = 2, timeout = 60 })
  ck(next(errs) == nil, "worker turns ran (" .. json.encode(errs) .. ")")
  eq(texts[1], "done", "worker 1 answered")
  local reqs = {}
  local f = io.open(log, "r")
  if f then
    for line in f:lines() do
      local ok, t = pcall(json.decode, line)
      if ok and type(t) == "table" and t.messages then reqs[#reqs + 1] = t end
    end
    f:close()
  end
  eq(#reqs, 2, "both worker turns reached the stand-in")
  for i, r in ipairs(reqs) do
    eq(r.output_config and r.output_config.effort, "high", "worker request " .. i .. " carries the effort")
  end
  if had_base then auth.set("base_url", had_base) else auth.clear("base_url") end
  pcall(http.request, { url = "http://127.0.0.1:" .. tostring(port) .. "/quit", method = "GET", timeout = 5 })
  srv:close()
else
  io.write("effort_plumbing: worker half skipped (needs python3, a POSIX shell)\n")
end

if fails == 0 then
  io.write("ok  effort_plumbing: worker effort reaches the request; none is never sent as a level\n")
else
  io.write(string.format("FAIL effort_plumbing: %d check(s) failed\n", fails))
  os.exit(1)
end
