-- harden.lua -- moving decisions down the tier ladder once they are proven.
--
-- Two halves.
--
-- SITES (works today, no model). A ladder site that defines `key` can have its
-- repeated decisions folded into a code-tier memo (lua/ladder.lua "HARDENING"):
-- a verdict a lower tier gave, that the llm sample agreed with `min_obs` times in
-- a row for the same key, is thereafter answered by code alone. It is rechecked
-- against the ladder at `recheck`; a disagreement drops the entry and `max_bad`
-- of them switch the site's hardening off. `/harden` is the surface.
--
-- WORKFLOWS. A workflow's capability calls carry a tier (code | jev | llm,
-- lua/workflow.lua), so a run says how much of it needed a model. `propose`
-- turns aligned traces into a compiled candidate (lua/mining/compile.lua), names
-- each residual model decision, and -- when a typed Jev spec is supplied for it
-- -- registers that decision as a ladder site `wf.<capability>` whose stages are
-- jev then the original model capability, so the rung below "llm" is real.
-- `admit` runs the evidence gate (lua/learning/promote.lua) and registers the
-- candidate inactive; activation, qualification and rollback stay the learning
-- registry's, so a candidate never runs because harden said so.
--
--   /harden                         what is hardened, per site
--   /harden on|off [<site>]         master or one site (the kill switch)
--   /harden clear <site>            forget a site's memo
--   /harden obs <n>                 observations required before promotion
local ladder = require("ladder")

local M = {}

-- ---- sites -------------------------------------------------------------------
function M.status()
  local rows = {}
  for _, id in ipairs(ladder.sites()) do
    local s = ladder.site(id)
    if s.key then
      local st = ladder.memo_stats(id)
      rows[#rows + 1] = { id = id, enabled = ladder.harden_enabled(id), entries = st.entries,
        promoted = st.promoted, bad = st.bad }
    end
  end
  return { master = ladder.harden_master(), min_obs = ladder.HARDEN.min_obs, sites = rows }
end

function M.describe()
  local s = M.status()
  local out = { string.format("harden: master=%s  min_obs=%d  recheck=%.2f  max_bad=%d",
    s.master and "on" or "off", s.min_obs, ladder.HARDEN.recheck, ladder.HARDEN.max_bad) }
  if #s.sites == 0 then out[#out + 1] = "  (no site can be hardened)" end
  for _, r in ipairs(s.sites) do
    out[#out + 1] = string.format("  %-20s %-3s  promoted=%d seen=%d rollbacks=%d",
      r.id, r.enabled and "on" or "off", r.promoted, r.entries, r.bad)
  end
  return table.concat(out, "\n")
end

function M.command(rest)
  local a, b = (rest or ""):match("^(%S*)%s*(%S*)")
  if a == "" then return M.describe() end
  if a == "on" or a == "off" then
    if b == "" then ladder.set_harden_master(a == "on"); return M.describe() end
    local ok, e = ladder.set_harden(b, a == "on")
    return ok ~= nil and M.describe() or ("harden: " .. e)
  elseif a == "clear" then
    if not ladder.site(b) then return "harden: unknown site: " .. b end
    ladder.memo_clear(b)
    return M.describe()
  elseif a == "obs" then
    local n = tonumber(b)
    if not n or n < 1 or n % 1 ~= 0 then return "harden: obs needs a whole number >= 1" end
    ladder.HARDEN.min_obs = n
    return M.describe()
  end
  return "usage: /harden [on|off [<site>]] | /harden clear <site> | /harden obs <n>"
end

-- ---- workflows ---------------------------------------------------------------
-- tiers(snapshot) -> { code = n, jev = n, llm = n, total = n, residual = { cap... } }
-- from a workflow run's invocation records.
function M.tiers(snapshot)
  local out = { code = 0, jev = 0, llm = 0, total = 0, residual = {} }
  local seen = {}
  for _, inv in ipairs(snapshot and snapshot.invocations or {}) do
    local t = inv.tier or "code"
    out[t] = (out[t] or 0) + 1
    out.total = out.total + 1
    if t == "llm" and not seen[inv.id] then seen[inv.id] = true; out.residual[#out.residual + 1] = inv.id end
  end
  table.sort(out.residual)
  return out
end

-- propose(alignment, opts) -> candidate, err
--   opts = the mining.compile.candidate options, plus
--   opts.jev = { [capability_id] = { state=, questions=, map= } } typed Jev
--   forms for residual decisions, and opts.call = { [capability_id] = fn(ctx) }
--   the original model call, kept as the fallback stage.
-- The candidate is inactive and carries `tiers` (what the compiled source calls
-- and which of those are residual model decisions) and `ladder_sites` (the
-- wf.<capability> sites registered for the residual decisions that have a spec).
function M.propose(alignment, opts)
  opts = opts or {}
  local copts = {}
  for k, v in pairs(opts) do if k ~= "jev" and k ~= "call" then copts[k] = v end end
  local candidate, err = require("mining.compile").candidate(alignment, copts)
  if not candidate then return nil, err end
  local residual = copts.residual_capabilities or {}
  local summary = { code = 0, llm = 0, residual = {} }
  for cap in pairs(residual) do summary.residual[#summary.residual + 1] = cap end
  table.sort(summary.residual)
  local calls = 0
  for _ in candidate.source:gmatch("ctx:call%(") do calls = calls + 1 end
  summary.llm = #summary.residual
  summary.code = math.max(0, calls - summary.llm)
  local registered = {}
  for _, cap in ipairs(summary.residual) do
    require("workflow").set_tier(cap, "llm")
    local spec = opts.jev and opts.jev[cap]
    if spec then
      local id = "wf." .. cap
      local stages = { ladder.jev(spec) }
      local call = opts.call and opts.call[cap]
      stages[#stages + 1] = ladder.llm(call or function() return nil end, "capability")
      ladder.define{ id = id, stages = stages, help = "residual decision of a compiled workflow" }
      registered[#registered + 1] = id
    end
  end
  candidate.tiers = summary
  candidate.ladder_sites = registered
  return candidate
end

-- admit(candidate, report, registry, id, version) -> true | nil, err
-- The evidence gate, then an INACTIVE registration. Activation is the learning
-- registry's (qualification + monitor), never this module's.
function M.admit(candidate, report, registry, id, version)
  local ok, e = pcall(require("learning.promote").check, candidate, report)
  if not ok then return nil, type(e) == "table" and e or { code = "promotion_denied", detail = tostring(e) } end
  if registry and registry.register then
    local v, why = registry:register(id, version, candidate)
    if not v then return nil, why end
  end
  return true
end

return M
