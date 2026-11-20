-- forkspawn.lua -- spawn{ fork = true }: a child that starts from a copy of its
-- parent's conversation, so its first request repeats the parent's prefix
-- (system, tools, messages) byte for byte and a prefix cache serves all of it.
--
-- Deterministic: every agent's model call goes through a scripted transport
-- (opts.stream, the seam tests/mockwire.lua locks in), injected by wrapping
-- thread.agent_opts so spawned children get it too. The swarm itself -- the
-- scheduler, the bus, await, the exit contract -- is the real one.
-- Run: BOGGART_HOME=$(mktemp -d) boggart --eval tests/forkspawn.lua
local json = require("json")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n  got:  ", tostring(a), "\n  want: ", tostring(b), "\n") end
end

bog.userdir = os.tmpname() .. "_boggart_fork_test"
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
local fork = require("fork")
auth.set("api_key", "test-key")

-- A harmless tool for the parent to call before it forks, so the copied
-- history holds a real tool exchange (the thing a fork saves re-doing).
bog.tools.register("probe", {
  description = "test probe", input_schema = { type = "object", properties = {} },
  run = function() return "probe output: 42 widgets in stock.txt" end,
})

bog.thread.max_agents = 8

-- ---- scripted transport ------------------------------------------------------
-- bodies[id] = the JSON of every request that agent made, encoded at the moment
-- of the call (body.messages is the live transcript, so it must be captured
-- then, not read later). The encoder sorts keys, so equal JSON is equal bytes.
local bodies, recs, scripts = {}, {}, {}
local function text_of(msg)
  if type(msg.content) == "string" then return msg.content end
  local t = {}
  for _, b in ipairs(msg.content or {}) do
    if b.type == "text" then t[#t + 1] = b.text end
    if b.type == "tool_result" then t[#t + 1] = tostring(b.content) end
  end
  return table.concat(t, "\n")
end
-- A child picks its script by a marker in its task text ("T:name").
local function script_for(rec, body)
  if scripts[rec.id] then return scripts[rec.id] end
  local last = body.messages[#body.messages]
  local mark = text_of(last):match("T:(%w+)")
  scripts[rec.id] = mark and scripts[mark]
  return scripts[rec.id]
end
local real_agent_opts = bog.thread.agent_opts
bog.thread.agent_opts = function(rec)
  local o = real_agent_opts(rec)
  recs[rec.id] = rec
  o.stream = function(body, sink)
    local enc = json.encode(body)
    bodies[rec.id] = bodies[rec.id] or {}
    table.insert(bodies[rec.id], enc)
    local fn = script_for(rec, body)
    local msg, stop
    if fn then msg, stop = fn(json.decode(enc), #bodies[rec.id]) end
    msg = msg or { role = "assistant", content = { { type = "text", text = "(no script)" } } }
    for _, b in ipairs(msg.content) do if b.type == "text" and sink then sink(b.text) end end
    msg.usage = { input_tokens = 10, output_tokens = 5 }
    return msg, stop or "end_turn"
  end
  return o
end

local function say(text) return { role = "assistant", content = { { type = "text", text = text } } }, "end_turn" end
local function call(text, id, name, input)
  return { role = "assistant", content = {
    { type = "text", text = text },
    { type = "tool_use", id = id, name = name, input = input } } }, "tool_use"
end
local function last_result(body)
  local m = body.messages[#body.messages]
  for _, b in ipairs(m.content) do if b.type == "tool_result" then return b.content end end
end
local function run_agent(rec, text)
  local out
  bog.sched.add(rec.id, coroutine.create(function()
    out = select(2, bog.api.run_on(rec.session, text, nil, rec.opts))
  end))
  bog.sched.run()
  return out
end

-- A parent shaped like the interactive root: no skills, so the whole registry
-- (probe and the swarm tools included) is on offer.
local function root_like(title)
  local rec = bog.thread.new_agent{ title = title }
  rec.skills, rec.allow, rec.instructions = {}, nil, nil
  rec.opts = bog.thread.agent_opts(rec)
  return rec
end

-- ===== 1. the forked child's first request extends the parent's last one ====
local coord = root_like("coordinator")
coord.session.effort = "high"
local child_id, await_out
scripts[coord.id] = function(body, n)
  if n == 1 then return call("Reading first.", "tu_probe", "probe", {}) end
  if n == 2 then return call("Forking for the count.", "tu_fork", "spawn",
    { task = "T:widgets count the widgets", fork = true }) end
  if n == 3 then
    child_id = (json.decode(last_result(body)) or {}).spawned
    return call("Waiting.", "tu_await", "await", { ids = { child_id } })
  end
  await_out = last_result(body)
  return say("all done")
end
scripts.widgets = function(_, n) return say("widgets: 42") end

run_agent(coord, "please analyse the stock")
ok(type(child_id) == "number", "fork spawn returned a child id")
ok(await_out and await_out:find("1 of 1 agents succeeded", 1, true), "await verdict counts the forked child")
ok(await_out and await_out:find("widgets: 42", 1, true), "the child's answer returns to the parent")

local P = json.decode(bodies[coord.id][2])  -- the request whose answer was the spawn
local C = json.decode(bodies[child_id][1])  -- the forked child's first request
eq(json.encode(C.system), json.encode(P.system), "child system blocks are the parent's, byte for byte")
eq(json.encode(C.tools), json.encode(P.tools), "child tool list is the parent's, byte for byte")
eq(C.model, P.model, "child model is the parent's")
eq(C.max_tokens, P.max_tokens, "child max_tokens is the parent's")
eq(C.reasoning_effort, "high", "child inherits the parent's effort")
ok(#C.messages == #P.messages + 2, "child messages = parent prefix + in-flight assistant + fork turn")
local prefix_same = true
for i = 1, #P.messages do
  if json.encode(C.messages[i]) ~= json.encode(P.messages[i]) then prefix_same = false end
end
ok(prefix_same, "child messages begin with the parent's last request messages, byte for byte")
-- the same holds on the OpenAI wire, which is what caches by exact prefix
do
  local wp = bog.api._to_openai_body(json.decode(bodies[coord.id][2]))
  local wc = bog.api._to_openai_body(json.decode(bodies[child_id][1]))
  local same = #wc.messages > #wp.messages
  for i = 1, #wp.messages do
    if json.encode(wc.messages[i]) ~= json.encode(wp.messages[i]) then same = false end
  end
  ok(same, "openai-wire request: the parent's whole message list is a prefix of the child's")
  eq(json.encode(wc.tools), json.encode(wp.tools), "openai-wire tools identical")
end
-- the in-flight spawn is answered, never left dangling, and the task follows it
local inflight, forkturn = C.messages[#P.messages + 1], C.messages[#P.messages + 2]
eq(inflight.role, "assistant", "the parent's in-flight assistant message is kept")
eq(inflight.content[2].type, "tool_use", "...with its spawn tool_use")
eq(forkturn.role, "user", "followed by one user turn")
eq(forkturn.content[1].type, "tool_result", "which answers the spawn first")
eq(forkturn.content[1].tool_use_id, "tu_fork", "...by its id")
eq(forkturn.content[1].content, fork.FORK_RESULT, "...with the constant fork result")
ok(forkturn.content[1].pending == nil, "no internal pending marker leaks to the wire")
ok(forkturn.content[2] and forkturn.content[2].type == "text"
   and forkturn.content[2].text:find("forked sub-agent of agent " .. coord.id, 1, true)
   and forkturn.content[2].text:find("T:widgets count the widgets", 1, true),
   "then the fork directive and the task")
-- the child saw the probe result the parent already had: nothing to re-read
ok(json.encode(C.messages):find("42 widgets in stock.txt", 1, true), "child carries the parent's tool results")

-- the parent's transcript is not modified by the fork
do
  local pm = coord.session.messages
  local res
  for i, m in ipairs(pm) do
    if m.role == "user" and type(m.content) == "table" then
      for _, b in ipairs(m.content) do
        if b.tool_use_id == "tu_fork" then res = b end
        ok(not (b.type == "text" and tostring(b.text):find("forked sub-agent", 1, true)),
          "parent message " .. i .. " has no fork directive")
      end
    end
  end
  ok(res and res.content:find('"spawned"', 1, true), "parent's own spawn result is the real one")
  eq(#pm, 8, "parent transcript: user, probe, result, spawn, result, await, result, answer")
end

-- ===== 2. message lists are copies, not shared tables =======================
do
  local parent = {
    { role = "user", content = "hi" },
    { role = "assistant", content = { { type = "text", text = "go" },
      { type = "tool_use", id = "a", name = "probe", input = { deep = { 1 } } },
      { type = "tool_use", id = "b", name = "spawn", input = { task = "x", fork = true } },
      { type = "tool_use", id = "c", name = "probe", input = {} } } },
    { role = "user", content = {
      { type = "tool_result", tool_use_id = "a", content = "done-a" },
      { type = "tool_result", tool_use_id = "b", content = "", pending = true } } },
  }
  local before = json.encode(parent)
  local child = fork.history(parent)
  eq(json.encode(parent), before, "history() leaves the parent list untouched")
  local r = child[3].content
  eq(#r, 3, "every tool_use in the in-flight message has a result")
  eq(r[1].content, "done-a", "a result the parent already had is kept")
  eq(r[2].content, fork.FORK_RESULT, "the pending spawn gets the fork result")
  eq(r[3].content, fork.UNRUN_RESULT, "a call that never ran is answered as not run")
  -- mutate one side at every depth; the other must not move
  child[1].content = "changed"
  child[2].content[2].input.deep[1] = 99
  child[3].content[1].content = "changed"
  child[#child + 1] = { role = "user", content = "extra" }
  eq(json.encode(parent), before, "mutating the child copy leaves the parent unchanged")
  local snap = json.encode(child)
  parent[2].content[1].text = "parent edit"
  parent[3].content[2].content = "parent result"
  eq(json.encode(child), snap, "mutating the parent leaves the child copy unchanged")

  -- and the live records: the child's session list is not the parent's
  local crec = recs[child_id]
  ok(crec.session.messages ~= coord.session.messages, "child session has its own message list")
  local shared = false
  for i = 1, math.min(#crec.session.messages, #coord.session.messages) do
    if crec.session.messages[i] == coord.session.messages[i] then shared = true end
  end
  ok(not shared, "no message table is shared between parent and child")

  -- a history with no in-flight round is copied as is
  local done = { { role = "user", content = "q" }, { role = "assistant", content = { { type = "text", text = "a" } } } }
  eq(json.encode(fork.history(done)), json.encode(done), "a finished transcript is copied unchanged")
end

-- ===== 3. fresh (non-fork) spawn is unchanged ===============================
do
  local c2 = root_like("coordinator 2")
  c2.session.effort = "high"
  local fresh_id
  scripts[c2.id] = function(body, n)
    if n == 1 then return call("Delegating.", "tu_s", "spawn", { task = "T:fresh do a thing" }) end
    if n == 2 then
      fresh_id = (json.decode(last_result(body)) or {}).spawned
      return call("Waiting.", "tu_w", "await", { ids = { fresh_id } })
    end
    return say("ok")
  end
  scripts.fresh = function() return say("fresh done") end
  run_agent(c2, "delegate something")
  local F = json.decode(bodies[fresh_id][1])
  eq(#F.messages, 1, "a fresh child starts with only its task")
  eq(F.messages[1].content, "T:fresh do a thing", "...exactly the task text, no directive")
  -- A fresh child inherits its parent's effort too (api.inherit_limits): an
  -- effort is a level, not a property of the conversation being copied.
  eq(F.reasoning_effort, "high", "a fresh child inherits the parent's effort")
  eq(recs[fresh_id].session.token_budget, bog.thread.default_token_budget, "fresh child budget is the default")
  ok(recs[fresh_id].forked_from == nil, "a fresh child is not marked forked")
  local has_comms = false
  for _, s in ipairs(recs[fresh_id].skills) do if s == "comms" then has_comms = true end end
  ok(has_comms, "a fresh child still gets the comms skill")
end

-- ===== 4. the exit contract holds for a forked child ========================
do
  local c3 = root_like("coordinator 3")
  local out1, out2
  local nowhere = bog.userdir .. "/never-written.txt"
  scripts[c3.id] = function(body, n)
    if n == 1 then return call("Two forks.", "tu_a", "spawn", {
      task = "T:schema answer", fork = true, schema = { type = "object", required = { "count" } } }) end
    if n == 2 then
      local id = json.decode(last_result(body)).spawned
      return call("Wait.", "tu_b", "await", { ids = { id } })
    end
    if n == 3 then
      out1 = last_result(body)
      return call("Next.", "tu_c", "spawn", { task = "T:nodeliver write it", fork = true,
        deliverables = { nowhere } })
    end
    if n == 4 then
      local id = json.decode(last_result(body)).spawned
      return call("Wait.", "tu_d", "await", { ids = { id } })
    end
    out2 = last_result(body)
    return say("done")
  end
  -- first answer is prose (fails the schema), the retry answers properly
  scripts.schema = function(_, n)
    if n == 1 then return say("there are some") end
    return say('here: {"count": 42}')
  end
  scripts.nodeliver = function() return say("I wrote it, honest") end
  run_agent(c3, "two jobs")
  ok(out1 and out1:find("1 of 1 agents succeeded", 1, true), "schema fork: retried into a valid answer")
  ok(out1 and out1:find('{"count": 42}', 1, true), "schema fork: the structured answer reaches the parent")
  ok(out2 and out2:find("0 of 1 agents succeeded", 1, true), "a fork that does not deliver is a failure")
  ok(out2 and out2:find("missing deliverable", 1, true), "...and says why")
  -- the second fork copied a transcript that already held the first fork's
  -- whole exchange; its prefix still matches the parent's request that spawned it
  local spawned_second
  for id, r in pairs(recs) do
    if r.forked_from == c3.id and bodies[id] and json.encode(bodies[id]):find("T:nodeliver", 1, true) then
      spawned_second = id
    end
  end
  local P2 = json.decode(bodies[c3.id][3])
  local C2 = json.decode(bodies[spawned_second][1])
  local same = #C2.messages == #P2.messages + 2
  for i = 1, #P2.messages do
    if json.encode(C2.messages[i]) ~= json.encode(P2.messages[i]) then same = false end
  end
  ok(same, "a later fork's first request also extends its parent's last request")
end

-- ===== 5. caps: no fork bomb ================================================
do
  local c4 = root_like("coordinator 4")
  local nested_result, outer_await
  scripts[c4.id] = function(body, n)
    if n == 1 then return call("Fork.", "tu_1", "spawn", { task = "T:nester try nesting", fork = true }) end
    if n == 2 then
      local id = json.decode(last_result(body)).spawned
      return call("Wait.", "tu_2", "await", { ids = { id } })
    end
    outer_await = last_result(body)
    return say("done")
  end
  scripts.nester = function(body, n)
    if n == 1 then return call("Fork again.", "tu_n", "spawn", { task = "T:widgets deeper", fork = true }) end
    nested_result = last_result(body)
    return say("could not nest")
  end
  run_agent(c4, "nest")
  ok(nested_result and nested_result:find("cannot fork again", 1, true), "a forked child cannot fork again")
  ok(outer_await and outer_await:find("1 of 1", 1, true), "...and the refused attempt does not break it")

  -- fork + agent/skills is refused: it would replace the prompt the fork shares
  local live_before = bog.thread.live
  local real_current = bog.sched.current
  bog.sched.current = function() return c4.id end
  local r1 = bog.tools_swarm.defs.spawn.run({ task = "x", fork = true, agent = "critic" })
  local r2 = bog.tools_swarm.defs.spawn.run({ task = "x", fork = true, skills = { "comms" } })
  ok(r1:find("cannot be combined", 1, true), "fork + agent is refused")
  ok(r2:find("cannot be combined", 1, true), "fork + skills is refused")
  -- the existing agent cap applies to a fork exactly as to a fresh spawn
  local cap = bog.thread.max_agents
  bog.thread.max_agents = bog.thread.live
  local r3 = bog.tools_swarm.defs.spawn.run({ task = "x", fork = true })
  ok(r3:find("agent cap reached", 1, true), "a fork at the agent cap is refused")
  bog.thread.max_agents = cap
  bog.sched.current = real_current
  eq(bog.thread.live, live_before, "refused forks create no agent")
  -- a fork needs a live parent conversation
  local okf, ef = pcall(bog.thread.spawn, { task = "x", fork = true, parent_id = 987654 })
  ok(not okf and tostring(ef):find("no live conversation", 1, true), "fork with no live parent errors clearly")
end

-- ===== 6. limits: inherited, narrowed only by the spawn ======================
do
  local parent = { id = 4242, session = { messages = {}, max_tokens = 7000, compact_at = 123456,
    effort = "low", token_budget = 1000, context_limit = 64000 }, allow = { probe = true } }
  local function child() return { session = { messages = {}, max_tokens = 16000, compact_at = 400000 } } end
  local a = child(); fork.adopt(a, parent, {}, 200000)
  eq(a.session.max_tokens, 7000, "max_tokens inherited")
  eq(a.session.compact_at, 123456, "compact_at inherited")
  eq(a.session.effort, "low", "effort inherited")
  eq(a.session.token_budget, 1000, "parent budget inherited")
  eq(a.session.context_limit, 64000, "learned context window inherited on the same model")
  ok(a.allow ~= parent.allow and a.allow.probe, "allow-set copied, not shared")
  eq(a.perms, nil, "no profile on either side: none on the fork")
  local guarded = { id = 7, session = {}, perms = { edit = { ["*"] = "deny" } } }
  local g = child(); fork.adopt(g, guarded, {}, 200000)
  eq(g.perms and g.perms.edit["*"], "deny", "a fork runs under its parent's permission profile")
  ok(g.perms ~= guarded.perms, "...as a copy")
  ok(fork.check(guarded, { perms = { bash = {} } }), "a second profile on top of the parent's is refused")
  eq(fork.check(guarded, {}), nil, "no spawn profile: allowed")
  eq(fork.check(parent, { perms = { bash = {} } }), nil, "a spawn profile under an unprofiled parent: allowed")
  local b = child(); fork.adopt(b, parent, { budget = 300, effort = "high", model = "other" }, 200000)
  eq(b.session.token_budget, 300, "a smaller spawn budget narrows")
  eq(b.session.effort, "high", "spawn effort overrides")
  eq(b.session.context_limit, nil, "a different model does not inherit the window")
  local c = child(); fork.adopt(c, parent, { budget = 5000 }, 200000)
  eq(c.session.token_budget, 1000, "a larger spawn budget cannot widen the parent's")
  local d = child(); fork.adopt(d, { id = 1, session = {} }, {}, 200000)
  eq(d.session.token_budget, 200000, "an unbounded parent still gives its fork the worker default")
end

if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)
io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
