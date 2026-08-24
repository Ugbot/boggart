-- thread.lua -- an agent = a session (transcript) + journal + skills + mailbox
-- + its own tool set, run as a cooperative coroutine (an actor). This module
-- builds agent records, runs their turns, and spawns children. "All agents are
-- actors": the coordinator and every sub-agent are built the same way here.
local M = {}

-- Build an agent record (creates its persisted thread/session row). Does NOT
-- The fanout cap: how many agents may exist at once.
--
-- This is the ONLY structural difference between "single-agent mode" and swarm
-- mode. Everything is a swarm; a lone agent is a swarm whose cap is 1, so it
-- cannot spawn and never needs the bus -- but it resolves skills, filters its
-- tools and builds its prompt through exactly the same code as a swarm actor.
-- Raising the cap is what turns one into the other.
M.max_agents = 1
M.live = 0
-- Live agent records by id (distinct from M.live, the count). The watchdog reads
-- this to find stalled agents; _run removes an agent when it exits.
M.live_recs = {}

-- A spawned worker carries an output-token ceiling so a single agent cannot burn
-- the fleet's budget (≈ wall-clock on a local model). Generous -- real work is
-- well under this; a furnace is not. Tunable; nil disables. run_on enforces it.
M.default_token_budget = 200000

-- Default reasoning effort for a spawned worker. Bounds over-thinking on
-- reasoning models (the 151:1 stall) without crippling hard tasks; a coordinator
-- can route a harder child to "high" or a trivial one to "low" per spawn. nil =
-- inherit; ignored by models with no effort knob.
M.default_effort = "medium"

function M.at_capacity()
  local cap = M.max_agents
  -- A local server has a fixed number of parallel slots (llama.cpp total_slots);
  -- spawning more concurrent agents than slots only queues them behind the
  -- server, so cap the fanout at the slot count. Remote endpoints report no
  -- slots, so their cap stays exactly what the user asked for.
  local slots = bog.api and bog.api.local_slots and bog.api.local_slots()
  if slots and slots > 0 and (cap < 0 or slots < cap) then cap = slots end
  return cap >= 0 and M.live >= cap
end

-- The tool/prompt policy an agent runs under. Shared by the lone agent and every
-- swarm actor: they run the identical turn loop on the identical (async) transport
-- -- the only per-agent difference is which tools/skills it may use, which is data.
--
-- An agent with no skills gets the whole registry, which is what keeps the
-- default REPL behaving exactly as before: skills narrow, they never widen.
function M.agent_opts(rec)
  return {
    -- Telemetry lineage: the whole fan-out shares run_id so KPIs group; run_on
    -- stamps every record with these.
    run_id = rec.run_id or rec.id,
    parent_id = rec.parent_id,
    system = function() return bog.prompt.agent_system(rec) end,
    tools = function()
      if not rec.allow or next(rec.allow) == nil then return bog.tools.schemas() end
      return bog.tools.schemas_for(rec.allow)
    end,
    run_tool = function(name, input)
      if rec.allow and next(rec.allow) ~= nil and not bog.tools.allowed(rec.allow, name) then
        return "Tool error: tool '" .. name .. "' is not permitted for this agent"
      end
      -- Approval gate for spawned sub-agents. The studio/cTUI set bog.approve so
      -- children honour the coordinator's permission mode. When it is unset
      -- (headless/CLI/swarm -- the workhorse), fall back to perm's headless
      -- policy instead of running write/edit/bash unattended, which is exactly
      -- what these agents used to do. May run under the scheduler.
      if bog.approve then
        local ok, why = bog.approve(name, input, rec.id)
        if ok == false then
          return "Tool error: [permission_error] " .. (why or "rejected by approval gate")
        end
      elseif bog.perm and bog.perm.headless_decision(name) == "deny" then
        return "Tool error: [permission_error] the " .. name .. " tool is gated for "
          .. "this agent and no approver is attached. Do not retry it."
      end
      return bog.tools.run(name, input)
    end,
    on_tool = bog.log_tool,
    -- Durable checkpoint: persist this agent's transcript to its thread row
    -- after each assistant message / tool result, so an interrupted turn can be
    -- resumed instead of restarted.
    checkpoint = function()
      pcall(bog.store.thread_save, rec.id,
        { messages = rec.session.messages, status = "running" })
    end,
  }
end

-- Build the record for the session's own agent (the lone one, or a swarm's
-- coordinator seen from the REPL). Skills resolve here exactly as they do for a
-- spawned child -- which is the whole point: skills work in single-agent mode
-- because there is only one kind of agent.
function M.session_agent(sess, skills)
  skills = skills or sess.skills or {}
  local instructions, allow, unknown = bog.skills.resolve(skills)
  if #unknown > 0 then
    error("unknown skill(s): " .. table.concat(unknown, ", ")
      .. " (see the `skills` tool for what exists)", 0)
  end
  -- The session's own agent occupies a slot: a cap of 1 means "just me", which
  -- is exactly what single-agent mode is. Counting it here is what makes
  -- at_capacity() mean the same thing for the root as for a spawned child.
  if M.live < 1 then M.live = 1 end
  local rec = {
    id = sess.id, skills = skills, allow = allow, instructions = instructions,
    may_spawn = not M.at_capacity(), session = sess,
  }
  rec.opts = M.agent_opts(rec)
  sess.agent = rec
  M.live_recs[rec.id] = rec
  return rec
end

-- start a coroutine. p: { agent?, skills?, model?, title?, parent_id? }
function M.new_agent(p)
  p = p or {}
  local spec = p.agent and (bog.agents.load(p.agent) or {}) or {}
  local skills = p.skills or spec.skills or {}
  -- every agent is an actor: guarantee it can communicate on the bus
  local has_comms = false
  for _, s in ipairs(skills) do if s == "comms" then has_comms = true end end
  if not has_comms then
    local t = {}
    for _, s in ipairs(skills) do t[#t + 1] = s end
    t[#t + 1] = "comms"
    skills = t
  end

  -- A misspelled skill name used to vanish here: the agent started without the
  -- tools it asked for and nothing said so. Refuse instead -- spawning an agent
  -- that quietly cannot do its job is worse than not spawning it.
  local instructions, allow, unknown = bog.skills.resolve(skills)
  if #unknown > 0 then
    error("unknown skill(s): " .. table.concat(unknown, ", ")
      .. " (see the `skills` tool for what exists)", 0)
  end
  local model = p.model or spec.model or bog.session.model
  local id = bog.store.thread_create{
    parent_id = p.parent_id, title = p.title or p.agent or "agent",
    model = model, status = "running",
    spec = { agent = p.agent, skills = skills },
  }

  local rec = {
    id = id, parent_id = p.parent_id, spec_name = p.agent, skills = skills,
    allow = allow, instructions = instructions, sys_override = spec.system,
    -- Telemetry: a child's run_id is its parent's (the coordinator) so a 1-level
    -- fan-out's records all group under one run. Exit contract: what this agent
    -- must produce (deliverables) and how it is checked (verify).
    run_id = p.run_id or p.parent_id or id,
    deliverables = p.deliverables, verify = p.verify,
    session = { id = id, model = model, messages = {}, max_tokens = 16000,
                compact_at = 400000, token_budget = M.default_token_budget,
                effort = p.effort or M.default_effort },
  }
  rec.may_spawn = not M.at_capacity()
  rec.opts = M.agent_opts(rec)
  M.live = M.live + 1
  M.live_recs[rec.id] = rec
  return rec
end

-- Is a declared deliverable actually present? A path must exist as a non-empty
-- file. (Globs are future work; Phase 1 takes exact paths.)
local function deliverable_present(pat)
  if sys.stat(pat) ~= "file" then return false end
  local st = sys.stat -- (stat only says "file"; emptiness check is best-effort)
  local f = io and io.open and io.open(pat, "r")
  if f then local first = f:read(1); f:close(); return first ~= nil end
  return true
end

-- Enforce the spawn's EXIT CONTRACT: did the agent DELIVER (its declared
-- artifacts exist) and does it VERIFY (a trusted checker passes)? An agent that
-- ran clean but produced nothing, or whose output fails the checker, is a
-- FAILURE -- not a silent "done". Returns delivered, verified, reason.
--   * A budget/round stop is always a failure.
--   * Verify runs TRUSTED (direct bog.tools.run, not the model or the allow-set)
--     and a checker "fails" if its output contains a Tool error or "ISSUE"/"FAIL".
local function check_exit_contract(rec, stop)
  if stop == "max_rounds" or stop == "token_budget" then
    return false, false, "stopped by budget: " .. stop
  end
  if rec.deliverables then
    for _, pat in ipairs(rec.deliverables) do
      if not deliverable_present(pat) then
        return false, nil, "missing deliverable: " .. tostring(pat)
      end
    end
  end
  if rec.verify then
    local vtool = (type(rec.verify) == "table" and rec.verify.tool) or rec.verify
    local vargs = (type(rec.verify) == "table" and rec.verify.args) or {}
    if not next(vargs) and rec.deliverables and rec.deliverables[1] then
      vargs = { path = rec.deliverables[1] }
    end
    local out = tostring(select(1, bog.tools.run(vtool, vargs)) or "")
    if out:find("Tool error", 1, true) or out:find("VERDICT: ISSUE", 1, true)
       or out:upper():find("FAIL", 1, true) then
      return true, false, "verify failed: " .. out:sub(1, 140)
    end
    return true, true, nil
  end
  return true, nil, nil
end

-- The coroutine body for a spawned child: run its task, enforce the exit
-- contract (with one bounded retry that feeds the failure back), persist the
-- honest status, record the exit for telemetry, and report to the parent. `ok`
-- on the bus now means delivered + verified -- not merely "did not crash".
function M._run(rec, task)
  local max_attempts = rec.max_attempts or 2
  local text, ok, delivered, verified, why, stop = "", false, true, nil, nil, nil
  for attempt = 1, max_attempts do
    local buf = {}
    local ran, _msg, _stop = pcall(bog.api.run_on, rec.session, task,
      function(s) buf[#buf + 1] = s end, rec.opts)
    stop = _stop
    text = table.concat(buf)
    if not ran then
      text = "agent error: " .. tostring(_msg); ok = false; why = text
      break -- a crash is not retried
    end
    delivered, verified, why = check_exit_contract(rec, stop)
    ok = delivered and (verified ~= false)
    if ok or attempt >= max_attempts then break end
    -- Bounded retry: feed the failure back and resume the same session.
    bog.log(string.format("agent %d failed exit contract (%s); retry %d/%d",
      rec.id, why or "?", attempt + 1, max_attempts))
    rec.session.inbox = rec.session.inbox or {}
    rec.session.inbox[#rec.session.inbox + 1] =
      "Your attempt did not satisfy the task: " .. (why or "unknown")
      .. ". Fix it now and produce the required result."
    task = nil -- resume (no new user turn); the inbox nudge rides the next request
  end

  local status = ok and "done" or "error"
  if not ok and why then text = text .. "\n[exit-contract] " .. why end
  if bog.telemetry then
    bog.telemetry.agent_exit(
      { run_id = rec.run_id or rec.id, agent_id = rec.id, parent_id = rec.parent_id },
      { delivered = delivered, verified = verified, reason = why, stop = stop })
  end
  bog.store.thread_save(rec.id, { messages = rec.session.messages, status = status })
  if rec.parent_id then
    swarm.send(rec.id, rec.parent_id, bog.json.encode{
      kind = "result", from = rec.id, agent = rec.spec_name or "agent", ok = ok, text = text,
    })
  end
  M.live_recs[rec.id] = nil
  bog.log(string.format("agent %d (%s) %s", rec.id, rec.spec_name or "agent", status))
end

-- Kill one agent from a controlling interface (an operator picking a worker off
-- while the rest run on). Unlike a bare sched.kill, this first tells the agent's
-- parent the child is gone -- a synthetic failed result on the bus -- so a
-- coordinator blocked in await() unblocks instead of hanging forever on a child
-- that will now never report. (A crash needs no such courtesy: _run's pcall
-- still sends a result. A whole-turn cancel kills the parent too, so it does
-- not either. This is only for targeted single-agent kills.)
function M.kill(id)
  local parent
  for _, r in ipairs(bog.store.thread_list(true)) do
    if r.id == id then parent = r.parent_id; break end
  end
  if parent then
    pcall(swarm.send, id, parent, bog.json.encode{
      kind = "result", from = id, agent = "agent", ok = false, text = "(killed by operator)",
    })
  end
  return bog.sched.kill(id)
end

-- Spawn a child actor; returns its id immediately (it runs when the scheduler
-- next resumes it).
function M.spawn(p)
  local rec = M.new_agent(p)
  local co = coroutine.create(function() M._run(rec, p.task or "") end)
  bog.sched.add(rec.id, co)
  bog.log(string.format("spawned agent %d (%s): %s", rec.id, p.agent or "agent",
    (p.task or ""):gsub("%s+", " "):sub(1, 60)))
  return rec.id
end

return M
