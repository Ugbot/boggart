-- shell/agent/approval.lua -- the swarm approval gate. Sub-agents spawned by the
-- coordinator used to run write/edit/bash entirely unattended -- only the chat
-- coordinator's own tools were gated. This makes spawned agents honour the
-- coordinator's permission mode too: in a permissive mode they proceed, in a
-- restrictive one their side-effecting tools are gated.
--
-- It installs a CLI-safe hook: it sets bog.approve, which lua/thread.lua's
-- agent_opts.run_tool consults for every spawned agent's tool call. The CLI
-- never sets bog.approve, so nothing changes there.
--
-- INTERACTIVE, per-sub-agent approval. This used to be refuse-only: a gated
-- tool under a restrictive mode returned false and the worker's write was
-- silently blocked -- the only recourse was to pre-authorise via the
-- coordinator's mode or kill the worker. It now PARKS instead. When a gated
-- tool needs approval it registers the request in `bog.approvals` (keyed by
-- agent id), flips that agent to "waiting on approval", and yields until the
-- user decides in the FLEET view (studio/data/core/swarmview.lua), which draws
-- the request and the Approve/Reject buttons. This mirrors the coordinator's
-- own gate in core/agentview.lua's run_tool -- `while rec.decision == nil do
-- coroutine.yield("approve") end` -- because a sub-agent runs the identical
-- turn loop under the same scheduler and can suspend at exactly this point.
--
-- Deny stays deny: chat mode (or any explicit per-tool "deny") still refuses
-- outright -- there is nothing to interactively approve when the policy is
-- "never". Only "ask" becomes an interactive request.
local perm = require "perm"

local M = {}

-- How long a parked request waits for someone to answer before it degrades to
-- the old refuse. The park is a real block, so this is the SAFETY FALLBACK: if
-- the FLEET view is not open (or nobody is watching), the worker is NEVER left
-- silently stuck -- after this it gets the ordinary permission error it would
-- have got before, which the model can respond to. When FLEET is open the
-- buttons resolve it long before this fires.
local APPROVAL_TIMEOUT = 120   -- seconds

-- The pending-approval registry, shared with SwarmView. Keyed by agent id --
-- the same id the roster rows and dash records use -- so a request lands in the
-- right agent's detail pane. `allow_all` remembers an "approve all from this
-- agent" so later calls from that worker proceed without asking again.
local pending = {}     -- agent_id -> { agent_id, name, input, summary, ts, decision }
local allow_all = {}   -- agent_id -> true

-- A one-line human form of what the sub-agent wants to run, for the roster
-- marker and the detail pane. bash is its command; write/edit is the path it
-- would touch; anything else falls back to whatever obvious field it carries.
local function summarise(name, input)
  return perm.summarise(name, input)
end

local function poke_redraw()
  local core = package.loaded["core"]
  if core then core.redraw = true end
end

function M.install()
  if M.installed then return end
  M.installed = true

  -- What SwarmView reads and writes. Mirrors bog.claims: a small table of
  -- functions the view calls, so the view holds no approval state of its own
  -- and the two cannot drift. Absent in the CLI (install() is never called
  -- there), which is exactly the CLI-safe contract bog.approve already keeps.
  bog.approvals = {
    -- The request outstanding for one agent, or nil. SwarmView uses this per
    -- roster row and in the detail pane.
    get = function(id) return pending[id] end,
    -- Every outstanding request, for a totals/marker sweep.
    list = function()
      local out = {}
      for _, rec in pairs(pending) do
        if rec.decision == nil then out[#out + 1] = rec end
      end
      return out
    end,
    -- The decision, set from the FLEET buttons. "always" grants this agent a
    -- blanket allow for the rest of its life and approves the request in hand.
    decide = function(id, decision)
      local rec = pending[id]
      if not rec then return end
      if decision == "always" then
        allow_all[id] = true
        rec.decision = "approve"
      else
        rec.decision = decision
      end
      poke_redraw()
    end,
  }

  bog.approve = function(name, input, agent_id)
    local studio = package.loaded["core.studio"]
    local v = studio and (studio.view or (studio.agent_view and studio.agent_view()))
    if not v then return true end -- no coordinator UI: don't block the swarm

    -- The coordinator's own turn is already gated by AgentView:run_tool; this
    -- hook is for OTHER actors.
    if v.turn_id and agent_id == v.turn_id then return true end

    local policy = v.policy_for and v:policy_for(name) or perm.policy_for(name, v)
    if policy == "allow" or v.approve_all then return true end
    -- Blanket allow the user granted this specific sub-agent from FLEET.
    if allow_all[agent_id] then return true end

    -- The refuse the gate has always returned, reused verbatim for deny, for a
    -- rejected request, and for a request nobody answered in time -- so the
    -- model sees one consistent permission error whichever way the block ends.
    local function refuse()
      return false, string.format("sub-agent #%s: '%s' needs approval (mode: %s)",
        tostring(agent_id), name, (v.mode_label and v:mode_label()) or v.mode or "?")
    end

    -- Deny is deny: refuse outright, exactly as before, with nothing to approve.
    if policy == "deny" then return refuse() end

    -- Only a real coroutine can park. A sub-agent always runs as a scheduler
    -- coroutine (lua/thread.spawn), so this holds today; guarding it means an
    -- unexpected synchronous caller degrades to the old refuse instead of
    -- crashing with "attempt to yield from outside a coroutine".
    if not coroutine.isyieldable() then return refuse() end

    -- Park. Register the request, flip the agent to "waiting on approval"
    -- (SwarmView:state_of reads `pending`), and yield until decided. lua/
    -- sched.lua classes the "approve" yield as runnable, so this re-polls once
    -- per scheduler sweep -- it never wedges the loop, and every other actor,
    -- the coordinator included, keeps running while this one waits.
    local rec = {
      agent_id = agent_id, name = name, input = input,
      summary = summarise(name, input), ts = os.time(), decision = nil,
    }
    pending[agent_id] = rec
    poke_redraw()

    local deadline = os.time() + APPROVAL_TIMEOUT
    while rec.decision == nil do
      if os.time() >= deadline then
        pending[agent_id] = nil
        return refuse()   -- fallback: never leave the worker silently stuck
      end
      coroutine.yield("approve")
    end
    pending[agent_id] = nil
    if rec.decision == "reject" then return refuse() end
    return true
  end
end

return M
