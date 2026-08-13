-- blackboard.lua -- a per-agent world-state: the shared table of boolean facts
-- an agent believes. Tools write to it as effects, the model asserts facts on
-- it, and the GOAP planner (lua/goap.lua) reads it as the start state for a
-- search. It is the durable, named form of the plan executor's ephemeral ctx.
--
-- Closed-world: an atom absent from the board is false. Per agent, because in a
-- swarm each actor has its own beliefs -- the blackboard is keyed by agent id,
-- so a coordinator and its children do not scribble over each other's world.
local M = {}

M.LIMITS = { atoms = 256 }   -- bounded per agent, asserted below

local store = {}             -- agent_id -> { atom -> true }

-- Best-effort current agent: a swarm actor if one is running, else the session,
-- else a single fixed board. Never nil, so callers need not special-case it.
function M.current()
  return (bog and bog.current_agent)
    or (bog and bog.session and bog.session.id)
    or "main"
end

local function board(agent)
  agent = agent or M.current()
  local b = store[agent]
  if not b then b = {}; store[agent] = b end
  return b
end

function M.get(atom, agent)
  return board(agent)[atom] == true
end

function M.set(atom, val, agent)
  assert(type(atom) == "string" and atom ~= "", "atom must be a non-empty string")
  local b = board(agent)
  if val then
    if not b[atom] then
      local n = 0
      for _ in pairs(b) do n = n + 1 end
      assert(n < M.LIMITS.atoms, "blackboard atom budget exhausted")
    end
    b[atom] = true
  else
    b[atom] = nil
  end
end

-- Apply an effect table { atom = bool, ... } in one shot.
function M.apply(effect, agent)
  for atom, val in pairs(effect) do M.set(atom, val, agent) end
end

-- The true-atoms as a set, which is what a planner wants as its start state.
function M.snapshot(agent)
  local out = {}
  for atom in pairs(board(agent)) do out[atom] = true end
  return out
end

function M.facts(agent)
  local out = {}
  for atom in pairs(board(agent)) do out[#out + 1] = atom end
  table.sort(out)
  return out
end

function M.clear(agent)
  store[agent or M.current()] = {}
end

return M
