-- tools_swarm.lua -- the swarm-only tools that let an agent orchestrate and
-- message peers. Registered into the tool registry when swarm mode starts.
-- "self" is always the currently-running agent (bog.sched.current()).
local json = require("json")
local M = {}

-- Messages popped from a mailbox during await that aren't the awaited results
-- are stashed here so the `inbox` tool can still surface them (no loss).
local stash = {}
local function stash_push(id, payload) stash[id] = stash[id] or {}; table.insert(stash[id], payload) end
local function stash_take(id)
  local s = stash[id]; stash[id] = nil
  return s or {}
end

-- A single child's result can be long; N of them concatenated into the
-- coordinator's transcript floods its window (and then compaction summarizes the
-- results away). Bound each child to a head+tail slice so a wide fan-in stays
-- legible -- the coordinator can ask a child for detail if it needs it.
local CHILD_CAP = 4000
local function clamp(s)
  s = tostring(s or "")
  if #s <= CHILD_CAP then return s end
  local head = math.floor(CHILD_CAP * 0.7)
  local tail = CHILD_CAP - head
  return s:sub(1, head) .. "\n…[" .. (#s - CHILD_CAP) .. " chars elided; ask the agent for detail]…\n"
    .. s:sub(#s - tail + 1)
end

local defs = {}

defs.spawn = {
  description = "Spawn a sub-agent (its own conversation thread) to work on a task in parallel; "
    .. "returns its id. Optionally name a standard agent (researcher/coder/critic) and/or skills. "
    .. "Pass `deliverables` (paths the agent MUST produce) and/or `verify` (a checker tool) to hold "
    .. "the agent to an exit contract: an agent that does not deliver + verify is reported as failed.",
  input_schema = {
    type = "object",
    properties = {
      task = { type = "string" },
      agent = { type = "string", description = "standard agent name" },
      model = { type = "string" },
      skills = { type = "array", description = "skill names" },
      deliverables = { type = "array", description = "absolute paths the agent must create for success" },
      verify = { type = "string", description = "a checker tool run (trusted) on the deliverable to confirm success" },
      effort = { type = "string", description = "reasoning effort for this child: minimal|low|medium|high|none (default medium). Use low for simple tasks, high for hard ones." },
    },
    required = { "task" },
  },
  run = function(a)
    if type(a.task) ~= "string" or a.task == "" then return "Tool error: spawn requires 'task'" end
    -- The fanout cap is what distinguishes single-agent mode from a swarm, and
    -- it is enforced here rather than by hiding the tool: refusing with the
    -- reason lets the model do the work itself instead of retrying blindly.
    if bog.thread.at_capacity() then
      return string.format(
        "Tool error: [validation_error] agent cap reached (%d): cannot spawn more agents. "
        .. "Do this work yourself.", bog.thread.max_agents)
    end
    local id = bog.thread.spawn{
      task = a.task, agent = a.agent, model = a.model, skills = a.skills,
      deliverables = a.deliverables, verify = a.verify, effort = a.effort,
      parent_id = bog.sched.current(),
    }
    return json.encode{ spawned = id }
  end,
}

defs.await = {
  description = "Wait for spawned sub-agents to finish and return their results. Pass the ids "
    .. "returned by spawn. Blocks (cooperatively) until every id has reported.",
  input_schema = {
    type = "object",
    properties = { ids = { type = "array" } },
    required = { "ids" },
  },
  run = function(a)
    local self = bog.sched.current()
    local pending, count = {}, 0
    for _, id in ipairs(a.ids or {}) do
      local n = tonumber(id)
      if n then pending[n] = true; count = count + 1 end
    end
    if count == 0 then return "Tool error: await requires a non-empty 'ids' array" end
    local results = {}
    while next(pending) do
      while true do
        local payload, jid = swarm.recv(self)
        if not payload then break end
        local ok, m = pcall(json.decode, payload)
        if ok and type(m) == "table" and m.kind == "result" and pending[m.from] then
          results[#results + 1] = m
          pending[m.from] = nil
          swarm.mark_processed(jid)
        else
          stash_push(self, payload) -- keep unrelated messages for `inbox`
          if jid then swarm.mark_processed(jid) end
        end
      end
      if next(pending) then coroutine.yield("recv") end
    end
    -- Computed verdict, prepended so the coordinator's own context carries the
    -- hard count -- a model reading "2 of 14 succeeded" cannot as easily narrate
    -- the fan-out as a success. (Today m.ok means the child did not crash; once
    -- Phase 1's exit contract lands it means delivered + verified.)
    local n_ok, n_failed = 0, 0
    for _, m in ipairs(results) do
      if m.ok then n_ok = n_ok + 1 else n_failed = n_failed + 1 end
    end
    local out = { string.format(
      "VERDICT (computed, not self-reported): %d of %d agents succeeded, %d failed. "
      .. "Report this honestly; do not call a partial fan-out a success.",
      n_ok, #results, n_failed) }
    for _, m in ipairs(results) do
      out[#out + 1] = string.format("### agent %d (%s)%s\n%s",
        m.from, m.agent or "agent", m.ok and "" or " [error]", clamp(m.text))
    end
    return table.concat(out, "\n\n")
  end,
}

defs.send = {
  description = "Send a message directly to another agent by id.",
  input_schema = {
    type = "object",
    properties = { to = { type = "integer" }, message = { type = "string" } },
    required = { "to", "message" },
  },
  run = function(a)
    local to = tonumber(a.to)
    if not to then return "Tool error: send requires numeric 'to'" end
    swarm.send(bog.sched.current(), to, json.encode{ kind = "msg", from = bog.sched.current(), text = a.message or "" })
    return "sent to " .. to
  end,
}

defs.publish = {
  description = "Publish a message to a topic; all current subscribers receive it.",
  input_schema = {
    type = "object",
    properties = { topic = { type = "string" }, message = { type = "string" } },
    required = { "topic", "message" },
  },
  run = function(a)
    if type(a.topic) ~= "string" then return "Tool error: publish requires 'topic'" end
    local n = swarm.publish(bog.sched.current(), a.topic,
      json.encode{ kind = "msg", from = bog.sched.current(), topic = a.topic, text = a.message or "" })
    return string.format("published to %d subscriber(s)", n)
  end,
}

defs.subscribe = {
  description = "Subscribe to a topic so you receive messages published to it (read via inbox).",
  input_schema = {
    type = "object",
    properties = { topic = { type = "string" } },
    required = { "topic" },
  },
  run = function(a)
    if type(a.topic) ~= "string" then return "Tool error: subscribe requires 'topic'" end
    swarm.subscribe(bog.sched.current(), a.topic)
    return "subscribed to " .. a.topic
  end,
}

defs.inbox = {
  description = "Read and drain your mailbox: returns messages other agents sent or published "
    .. "to your subscribed topics.",
  input_schema = { type = "object", properties = {} },
  run = function(a)
    local self = bog.sched.current()
    local msgs = {}
    for _, payload in ipairs(stash_take(self)) do msgs[#msgs + 1] = payload end
    while true do
      local payload, jid = swarm.recv(self)
      if not payload then break end
      msgs[#msgs + 1] = payload
      if jid then swarm.mark_processed(jid) end
    end
    if #msgs == 0 then return "(inbox empty)" end
    local out = {}
    for _, p in ipairs(msgs) do
      local ok, m = pcall(json.decode, p)
      if ok and type(m) == "table" then
        out[#out + 1] = string.format("from %s%s: %s", tostring(m.from or "?"),
          m.topic and (" [" .. m.topic .. "]") or "", m.text or m.kind or "")
      else
        out[#out + 1] = tostring(p)
      end
    end
    return table.concat(out, "\n")
  end,
}

defs.threads = {
  description = "List the live agents/threads in this swarm and their status.",
  input_schema = { type = "object", properties = {} },
  run = function(a)
    local rows = bog.store.thread_list(true)
    local out = {}
    for _, r in ipairs(rows) do
      out[#out + 1] = string.format("%d\t%s\t%s", r.id, r.status or "?", r.title or "")
    end
    return #out > 0 and table.concat(out, "\n") or "(no threads)"
  end,
}

function M.register()
  for name, def in pairs(defs) do bog.tools.register(name, def) end
end

M.defs = defs
return M
