-- fork.lua -- `spawn{ fork = true }`: a child that starts as a copy of its
-- parent's conversation instead of a blank one.
--
-- Two reasons to want this. A fresh child re-reads every file the parent already
-- read, because all it has is its task text. And its requests share nothing with
-- the parent's: providers that cache by exact prompt prefix (OpenAI-compatible
-- servers, llama.cpp slots, Anthropic's breakpoints) only hit when the request
-- BEGINS with bytes they have seen. A forked child's first request is the
-- parent's last request -- same system blocks, same tool list, same messages --
-- with the fork's task appended, so the whole parent prefix is a cache hit and
-- the child arrives knowing what the parent knows.
--
-- Everything that decides those bytes is taken from the parent here, so the
-- prefix stays identical by construction rather than by coincidence:
--   * system: the parent's prompt fields (agent_system reads only these)
--   * tools:  the parent's allow-set
--   * model:  the parent's route (thread.new_agent resolves it)
-- tests/forkspawn.lua compares the two request bodies byte for byte.
local M = {}

-- Plain data only (strings, numbers, booleans, tables), which is all a
-- transcript holds. A deep copy rather than a shallow one because the turn loop
-- mutates blocks in place (run_tool_round finalises a pending tool_result block,
-- repair_history splices results into an existing message): a shared block
-- would let the child rewrite the parent's history, or the reverse.
local function copy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local t = {}
  seen[v] = t
  for k, x in pairs(v) do t[copy(k, seen)] = copy(x, seen) end
  return t
end
M.copy = copy

-- What a forked child sees as the result of a tool call the parent had not
-- finished when it forked. The spawn that started the fork is one of these: it
-- is still running (it is what is creating the child), so it has no result yet.
--
-- Why answer the in-flight calls instead of dropping the in-flight assistant
-- message: that message holds the parent's reasoning up to the spawn, which is
-- exactly the context a fork exists to carry, and keeping it means the child's
-- prefix also matches the parent's NEXT request up to and including it. A
-- tool_use with no result is rejected by every wire, so each one gets an
-- explicit result. The texts are constants, not per-child, so sibling forks
-- spawned from the same message share that prefix too.
M.FORK_RESULT = "[forked] This call started a forked sub-agent; the forked "
  .. "sub-agent's task follows."
M.UNRUN_RESULT = "[not run] The conversation was forked before this call "
  .. "finished; its result is not available in the fork."

local function is_fork_spawn(b)
  return b.name == "spawn" and type(b.input) == "table" and b.input.fork == true
end

-- The child's starting transcript: a deep copy of `messages`, with the trailing
-- in-flight tool round (if any) closed. Results the parent already has are kept
-- (a `read` that ran before the spawn in the same round is real context); a
-- pending marker or a missing result becomes one of the texts above. The
-- parent's list is never touched.
function M.history(messages)
  local out = copy(messages or {})
  local idx
  for i = #out, 1, -1 do
    if out[i].role == "assistant" then idx = i; break end
  end
  local am = idx and out[idx]
  if not (am and type(am.content) == "table") then return out end
  local uses = {}
  for _, b in ipairs(am.content) do
    if b.type == "tool_use" then uses[#uses + 1] = b end
  end
  if #uses == 0 then return out end

  local rmsg = out[idx + 1]
  if not (rmsg and rmsg.role == "user") then
    rmsg = { role = "user", content = {} }
    table.insert(out, idx + 1, rmsg)
  elseif type(rmsg.content) ~= "table" then
    local text = rmsg.content
    rmsg.content = {}
    if type(text) == "string" and text ~= "" then
      rmsg.content[1] = { type = "text", text = text }
    end
  end
  -- Keep finished results in place; drop pending markers (they are rewritten
  -- below). Results must lead the message, so anything else follows them.
  local results, rest, have = {}, {}, {}
  for _, b in ipairs(rmsg.content) do
    if b.type == "tool_result" then
      if not b.pending then results[#results + 1] = b; have[b.tool_use_id] = true end
    else
      rest[#rest + 1] = b
    end
  end
  for _, u in ipairs(uses) do
    if not have[u.id] then
      results[#results + 1] = { type = "tool_result", tool_use_id = u.id,
        content = is_fork_spawn(u) and M.FORK_RESULT or M.UNRUN_RESULT }
    end
  end
  for _, b in ipairs(rest) do results[#results + 1] = b end
  rmsg.content = results
  return out
end

-- The user text the child starts on. Said once, plainly: the copied history is
-- the parent's, so without this the child tends to carry on with the parent's
-- whole job instead of its slice of it.
function M.directive(parent_id, task)
  return string.format("You are a forked sub-agent of agent %s. Everything above "
    .. "is the parent's conversation, copied at the moment it spawned you: use it as "
    .. "context, but do not continue the parent's work. Do only the task below, then "
    .. "end with a clear, self-contained answer for the parent. You cannot fork "
    .. "again.\n\nYour task:\n", tostring(parent_id)) .. tostring(task or "")
end

-- The output-token ceiling for a forked child: the parent's own ceiling, made
-- tighter (never looser) by the spawn's `budget`; a parent with no ceiling (the
-- interactive root) still gets the per-worker default, so a fork cannot become
-- the one unbounded agent in a fleet.
local function budget(asked, parent_cap, default)
  asked = tonumber(asked)
  if asked and parent_cap then return math.min(asked, parent_cap) end
  return asked or parent_cap or default
end

-- Why this fork cannot be built, or nil. Checked before the child's row exists.
--
-- A fork is its parent with a narrower job, so it runs under the parent's
-- permission profile; without that, a read-only reviewer could fork itself a
-- copy that writes. A profile on the spawn as well would need the two combined,
-- and perm.decide takes one agent profile, so that case is refused rather than
-- resolved by silently dropping either.
function M.check(parent, p)
  if parent.perms and p.perms then
    return "this agent has a permission profile, which its fork inherits; "
      .. "spawn the fork without `perms`"
  end
  return nil
end

-- Turn a freshly built child record (thread.new_agent) into a fork of `parent`.
-- Runs before the record's opts are built, so the invocation context and the
-- tool/system closures see the parent's allow-set and prompt fields.
--   p: the spawn params (effort / budget may narrow; agent/skills are refused
--      by the caller because they would change the prompt)
function M.adopt(rec, parent, p, default_budget)
  rec.forked_from = parent.id or p.parent_id
  -- The prompt and the tool offer: exactly the parent's, so the head of every
  -- request matches. may_spawn is copied for the same reason (it selects the
  -- swarm preamble); the agent cap is still enforced by the spawn tool itself.
  rec.skills = copy(parent.skills)
  rec.allow = copy(parent.allow)
  rec.instructions = parent.instructions
  rec.sys_override = parent.sys_override
  rec.may_spawn = parent.may_spawn
  rec.perms = p.perms or copy(parent.perms)

  local ps, s = parent.session or {}, rec.session
  s.messages = M.history(ps.messages)
  s.max_tokens = ps.max_tokens or s.max_tokens
  s.max_rounds = ps.max_rounds
  s.compact_at = ps.compact_at or s.compact_at
  s.compact_ratio = ps.compact_ratio
  s.memory = ps.memory
  -- The parent's effort unless the spawn names one; nil stays nil (the parent
  -- sends no effort, so neither does the fork).
  s.effort = p.effort or ps.effort
  s.token_budget = budget(p.budget, tonumber(ps.token_budget), default_budget)
  -- A learned context window is evidence about the model, so it carries only
  -- when the fork stays on the parent's model.
  if not p.model then s.context_limit = ps.context_limit end
end

return M
