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

function M.at_capacity()
  return M.max_agents >= 0 and M.live >= M.max_agents
end

-- The tool/prompt policy an agent runs under. Shared by the lone agent and every
-- swarm actor: the only per-mode differences are the transport (`async`) and
-- whether spawning is permitted, both of which are data.
--
-- An agent with no skills gets the whole registry, which is what keeps the
-- default REPL behaving exactly as before: skills narrow, they never widen.
function M.agent_opts(rec, async)
  return {
    async = async or false,
    system = function() return bog.prompt.agent_system(rec) end,
    tools = function()
      if not rec.allow or next(rec.allow) == nil then return bog.tools.schemas() end
      return bog.tools.schemas_for(rec.allow)
    end,
    run_tool = function(name, input)
      if rec.allow and next(rec.allow) ~= nil and not bog.tools.allowed(rec.allow, name) then
        return "Tool error: tool '" .. name .. "' is not permitted for this agent"
      end
      return bog.tools.run(name, input)
    end,
    on_tool = bog.log_tool,
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
  rec.opts = M.agent_opts(rec, false)
  sess.agent = rec
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
    session = { id = id, model = model, messages = {}, max_tokens = 16000, compact_at = 400000 },
  }
  rec.may_spawn = not M.at_capacity()
  rec.opts = M.agent_opts(rec, true)
  M.live = M.live + 1
  return rec
end

-- The coroutine body for a spawned child: run its task to completion, persist,
-- and report the result back to its parent over the bus.
function M._run(rec, task)
  local buf = {}
  local ok, err = pcall(bog.api.run_on, rec.session, task, function(s) buf[#buf + 1] = s end, rec.opts)
  local text = table.concat(buf)
  local status = ok and "done" or "error"
  if not ok then text = "agent error: " .. tostring(err) end
  bog.store.thread_save(rec.id, { messages = rec.session.messages, status = status })
  if rec.parent_id then
    swarm.send(rec.id, rec.parent_id, bog.json.encode{
      kind = "result", from = rec.id, agent = rec.spec_name or "agent", ok = ok, text = text,
    })
  end
  bog.log(string.format("agent %d (%s) %s", rec.id, rec.spec_name or "agent", status))
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
