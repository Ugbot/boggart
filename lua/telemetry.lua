-- telemetry.lua -- agent telemetry as an append-only span log over the record
-- envelope (bog.store.records). The span tree is run -> agent -> turn -> tool;
-- each event closes into one record row. Context is passed EXPLICITLY (no
-- ambient current-span globals), aggregated to turn/tool boundaries (never per
-- streamed delta, so it never hammers the store), and it is a NO-OP when the
-- store is absent -- tests and bare runs pay nothing.
--
-- This is the scoreboard the whole reliability layer is measured against: turn
-- spans carry model/TTFB/tokens/tool-calls/think-vs-output; agent:exit carries
-- delivered/verified; decision rows carry every allow/deny. M.kpis() folds a
-- run's rows into deliverable rate, false-success rate, think:output and
-- tokens/artifact -- "as good as the code layer" made countable.
local M = {}
M.enabled = true

local function ready()
  return M.enabled and bog and bog.store and bog.store.record_append
end

-- Monotonic milliseconds -- the loop's own clock -- for durations and TTFB.
function M.now_ms()
  local ok, uv = pcall(require, "uv")
  if ok and uv and uv.now then return uv.now() end
  return os.time() * 1000
end

-- ctx = { run_id, agent_id, parent_id }: the lineage every record is stamped
-- with, so a whole fan-out shares one run_id and KPIs group cleanly.
local function emit(kind, ctx, payload)
  if not ready() then return end
  ctx = ctx or {}
  pcall(bog.store.record_append, kind, {
    run_id = ctx.run_id, agent_id = ctx.agent_id, parent_id = ctx.parent_id,
    payload = payload,
  })
end

-- One model round: { model, provider, ttfb_ms, in_tokens, out_tokens,
-- tool_calls, think_chars, text_chars, stop }.
function M.turn(ctx, d) emit("span:turn", ctx, d) end
-- One tool invocation: { name, ok, ms }.
function M.tool(ctx, d) emit("span:tool", ctx, d) end
-- A permission decision at the moment it was made: { tool, policy, decision }.
function M.decision(ctx, d) emit("decision", ctx, d) end
-- An agent's exit-contract outcome: { delivered, verified, checker, reason, stop }.
function M.agent_exit(ctx, d) emit("agent:exit", ctx, d) end

local function decode(s)
  if not s or s == "" then return {} end
  local ok, d = pcall(function() return bog.json.decode(s) end)
  return (ok and type(d) == "table") and d or {}
end

-- The most recent exit-contract outcome for an agent: { delivered, verified,
-- reason, stop } or nil. Lets a UI say WHY an agent failed, not just "error".
function M.agent_status(agent_id)
  if not (bog.store and bog.store.records_recent) then return nil end
  for _, r in ipairs(bog.store.records_recent(500)) do -- newest first
    if r.kind == "agent:exit" and r.agent_id == agent_id then return decode(r.payload) end
  end
  return nil
end

-- Fold a run's records into the scoreboard. Cheap; reads records_for(run_id).
function M.kpis(run_id)
  local rows = (bog.store.records_for and bog.store.records_for(run_id)) or {}
  local agents = {}
  local function ag(id)
    id = id or 0
    agents[id] = agents[id] or { turns = 0, tool_calls = 0, out = 0,
      think = 0, text = 0, delivered = nil, verified = nil }
    return agents[id]
  end
  local turns, tool_calls, out_tok, think_c, text_c = 0, 0, 0, 0, 0
  local decisions = { allow = 0, deny = 0, ask = 0 }
  for _, r in ipairs(rows) do
    local p = decode(r.payload)
    local a = ag(r.agent_id)
    if r.kind == "span:turn" then
      turns = turns + 1; a.turns = a.turns + 1
      out_tok = out_tok + (p.out_tokens or 0); a.out = a.out + (p.out_tokens or 0)
      think_c = think_c + (p.think_chars or 0); a.think = a.think + (p.think_chars or 0)
      text_c = text_c + (p.text_chars or 0); a.text = a.text + (p.text_chars or 0)
      tool_calls = tool_calls + (p.tool_calls or 0); a.tool_calls = a.tool_calls + (p.tool_calls or 0)
    elseif r.kind == "agent:exit" then
      a.delivered = p.delivered and true or false
      a.verified = p.verified
    elseif r.kind == "decision" then
      local dec = p.decision or p.policy
      if decisions[dec] ~= nil then decisions[dec] = decisions[dec] + 1 end
    end
  end
  -- Fleet rollup over the CHILD agents (agent_id ~= run_id): the coordinator's
  -- own turns are orchestration, not deliverables.
  local n_agents, n_delivered, n_false = 0, 0, 0
  for id, a in pairs(agents) do
    if id ~= run_id and id ~= 0 then
      n_agents = n_agents + 1
      if a.delivered then n_delivered = n_delivered + 1 end
      -- False success: an agent that reported delivered but whose verify failed.
      if a.delivered == true and a.verified == false then n_false = n_false + 1 end
    end
  end
  return {
    turns = turns, tool_calls = tool_calls, out_tokens = out_tok,
    think_chars = think_c, text_chars = text_c,
    think_output_ratio = text_c > 0 and (think_c / text_c) or nil,
    agents = n_agents, delivered = n_delivered,
    deliverable_rate = n_agents > 0 and (n_delivered / n_agents) or nil,
    false_success = n_false,
    tokens_per_artifact = n_delivered > 0 and (out_tok / n_delivered) or nil,
    decisions = decisions,
    per_agent = agents,
  }
end

return M
