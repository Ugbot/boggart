-- tests/spawntools.lua -- which tools a spawned child is offered.
--
-- Every agent gets the `comms` skill so it can talk on the bus. That grant must
-- ADD the bus tools, never narrow: a plain `spawn` (no agent, no skills) used to
-- end up with only send/publish/subscribe/inbox, because the implicit comms
-- grant made the child's allow set non-empty and a non-empty allow set offers
-- only what it names. A delegated child that cannot read, write or run anything
-- is useless. Skills that grant tools still narrow, exactly as before.
--
-- Fully offline: every model call goes through a scripted transport
-- (opts.stream), and each request's tool names are recorded.
-- Run: boggart --eval tests/spawntools.lua
local json = require("json")

local fails = 0
local function ck(cond, msg) if not cond then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

bog.userdir = os.tmpname() .. "_boggart_spawntools_test"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()
swarm.attach(bog.db)

bog.sched = require("sched")
bog.skills = require("skills")
bog.agents = require("agents")
bog.thread = require("thread")
bog.tools_swarm = require("tools_swarm")
bog.tools_swarm.register()
bog.thread.max_agents = 8

-- No dispatch, and approve every gated call: this is about the offered tool set,
-- not the permission gate (spawning a named agent asks for approval).
if bog.dispatch and bog.dispatch.set_enabled then pcall(bog.dispatch.set_enabled, false) end
local real_approve = bog.approve
bog.approve = function() return true end

local function tool_names(body)
  local out = {}
  for _, t in ipairs((body and body.tools) or {}) do
    out[#out + 1] = t.name or (t["function"] and t["function"].name)
  end
  return out
end
local function set_of(list) local s = {} for _, n in ipairs(list) do s[n] = true end return s end
local function sorted(list) local c = {} for i, n in ipairs(list) do c[i] = n end table.sort(c) return c end
local function same(a, b) return table.concat(sorted(a), ",") == table.concat(sorted(b), ",") end

-- ---- scripted transport ----------------------------------------------------
-- first_tools[agent id] = tool names offered on that agent's FIRST request.
local first_tools = {}
local script = {} -- [agent id] = list of replies, consumed in order
local function scripted(sess_id)
  return function(body, sink)
    if not first_tools[sess_id] then first_tools[sess_id] = tool_names(body) end
    local q = script[sess_id]
    local reply = q and table.remove(q, 1)
    if reply then return reply, reply.stop end
    if sink then sink("done") end
    return { role = "assistant", content = { { type = "text", text = "done" } },
             usage = { output_tokens = 1 } }, "end_turn"
  end
end
local function tool_use(id, name, input)
  return { role = "assistant", stop = "tool_use",
           content = { { type = "tool_use", id = id, name = name, input = input } },
           usage = { output_tokens = 1 } }
end

-- Every agent built by the thread layer (root and children) talks to the script.
local real_opts = bog.thread.agent_opts
bog.thread.agent_opts = function(rec)
  local o = real_opts(rec)
  o.stream = scripted(rec.id)
  return o
end

-- ---- the coordinator: a skill-less session agent ---------------------------
local sess = { id = bog.store.thread_create{ title = "root", model = "mock", status = "running" },
               model = "mock", messages = {}, max_tokens = 1000 }
local root = bog.thread.session_agent(sess, {})
root.may_spawn = true

-- Its turn spawns three children through the real `spawn` tool:
--   plain       -- no agent, no skills
--   narrow      -- skills = { "data" } (grants sql, kv)
--   critic      -- agent = "critic" (spec skills: core, code_review)
script[root.id] = {
  tool_use("t1", "spawn", { task = "plain child task" }),
  tool_use("t2", "spawn", { task = "narrow child task", skills = { "data" } }),
  tool_use("t3", "spawn", { task = "critic child task", agent = "critic" }),
}
local spawned, recs = {}, {}
local real_spawn = bog.thread.spawn
bog.thread.spawn = function(p)
  local id = real_spawn(p)
  spawned[#spawned + 1] = id
  recs[id] = bog.thread.live_recs[id]
  return id
end

local _, stop = bog.api.run_on(sess, "delegate", nil, root.opts)
ck(stop == "end_turn", "coordinator turn completed via the script (stop=" .. tostring(stop) .. ")")
ck(#spawned == 3, "coordinator spawned three children (got " .. #spawned .. ")")
bog.sched.run()

local parent = first_tools[root.id] or {}
local plain = first_tools[spawned[1]] or {}
local narrow = first_tools[spawned[2]] or {}
local critic = first_tools[spawned[3]] or {}
local comms = { "send", "publish", "subscribe", "inbox" }

-- Parent sanity: the skill-less root is offered the whole registry.
ck(same(parent, (function() local t = {} for _, s in ipairs(bog.tools.schemas()) do t[#t + 1] = s.name end return t end)()),
  "skill-less coordinator is offered bog.tools.schemas()")

-- 1. A plain child sees the parent's tools (plus comms, which the parent has).
local want = {}
for _, n in ipairs(parent) do want[#want + 1] = n end
local pset = set_of(parent)
for _, n in ipairs(comms) do if not pset[n] then want[#want + 1] = n end end
ck(table.concat(plain, ",") == table.concat(want, ","),
  "plain child is offered exactly the parent's tools (+comms)\n    parent: "
  .. table.concat(parent, ",") .. "\n    child:  " .. table.concat(plain, ","))
local cset = set_of(plain)
for _, n in ipairs({ "read", "write", "edit", "bash" }) do
  ck(cset[n], "plain child is offered `" .. n .. "`")
end
for _, n in ipairs(comms) do ck(cset[n], "plain child is offered comms `" .. n .. "`") end

-- 2. A child whose skills grant tools is narrowed to them plus comms.
ck(same(narrow, { "sql", "kv", "send", "publish", "subscribe", "inbox" }),
  "skills={data} child is narrowed to sql,kv + comms (got " .. table.concat(sorted(narrow), ",") .. ")")

-- 3. An agent spec with skills keeps its narrowing.
local _, callow = bog.skills.resolve({ "core", "code_review", "comms" })
local cwant = {}
for _, s in ipairs(bog.tools.schemas_for(callow)) do cwant[#cwant + 1] = s.name end
ck(#critic > 0 and same(critic, cwant),
  "critic child is narrowed to its spec's skills + comms (got " .. table.concat(sorted(critic), ",") .. ")")
ck(not set_of(critic).sql and #critic < #parent, "critic child is narrower than the parent")

-- 4. The allow set also gates execution (invoke.context), so check the record:
--    a plain child is unrestricted, a narrowed one is not.
local plain_rec, narrow_rec = recs[spawned[1]], recs[spawned[2]]
ck(plain_rec and (not plain_rec.allow or next(plain_rec.allow) == nil),
  "plain child's allow set is unrestricted")
ck(narrow_rec and narrow_rec.allow and narrow_rec.allow.sql and narrow_rec.allow.send
  and not narrow_rec.allow.read, "narrow child's allow set is data + comms only")

bog.thread.agent_opts = real_opts
bog.thread.spawn = real_spawn
bog.approve = real_approve

if fails == 0 then
  io.write("ok  spawntools: plain children get the full registry; skills still narrow\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails)); os.exit(1)
end
