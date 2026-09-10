-- skill: supervisor -- read the live swarm: fleet status, plan progress, stuck
-- or failed agents, stalled plans, claims. Report what needs attention.
return {
  description = "Supervise the swarm: read live fleet status (who is running, how long, whether "
    .. "stuck), plan progress (what is done/running/failed), cross-check claims, and report "
    .. "exactly what needs attention. Use whenever asked to check on, watch, or debug other agents.",
  -- before: STEPs 1-3 are deterministic reads (fleet_status, plan_status,
  -- swarm_report, all no-arg). Run them as CODE and thread the results in, so
  -- the model starts at STEP 4 (judgment) already holding the state. When
  -- swarm_report says CLEAR, there is nothing to act on -- short-circuit with
  -- zero model turns.
  before = function()
    local fleet = bog.C("fleet_status")({})
    local plans = bog.C("plan_status")({})
    local report = bog.C("swarm_report")({})
    if type(report) == "string" and report:find("CLEAR") and not report:find("STUCK") then
      return { done = "swarm is CLEAR -- nothing needs attention.\n\n" .. report }
    end
    return { set = { fleet = fleet, plans = plans, report = report } }
  end,

  instructions = function(ctx)
    local fleet = (ctx and ctx.fleet) or "(run fleet_status)"
    local plans = (ctx and ctx.plans) or "(run plan_status)"
    local report = (ctx and ctx.report) or "(run swarm_report)"
    return [[
You are the supervisor of the swarm. The live state is already read (below).
Your job is to know what every agent is doing, whether anything is stuck or
broken, and to report it plainly. You are a READER: you never edit plans or
nudge agents without saying what you are doing.

## FLEET
]] .. fleet .. [[

## PLANS
]] .. plans .. [[

## SUPERVISION PASS (swarm_report)
]] .. report .. [[

A running agent silent for more than 10 minutes is STUCK. swarm_report already
cross-checked stuck agents, FAILED steps, STALLED plans, undispatched 'planning'
plans, and claims held by dead agents.

## ACT ON WHAT YOU FIND
- Stuck agent: check threads, read its mail (inbox), then either nudge it
  (send to=<id> message="...") or tell the human it needs killing/restarting.
- Failed step in an active plan: say which step, which plan, and what the error
  says. Suggest (or, if asked, do) a retry as a new step with the same deps.
- Stalled plan: say which plan and which steps are blocked on what.
- Claim held by a dead agent: say which file and which agent.

## STEP 5 — REPORT, THEN VERIFY
- Report findings to the human in order of severity: STUCK agents first, then
  failed steps, then stalled plans, then notes. Be specific: ids, durations,
  error text. If the dashboard is wanted, panel_refresh updates the studio panel.
- Self-check: your report must cover everything swarm_report flagged. If you
  nudge or change anything, re-run swarm_report to confirm the picture is now
  accurate before you claim it is.
]]
  end,
  tools = {
    "fleet_status", "plan_status", "swarm_report", "panel_refresh",
    "threads", "inbox", "send", "claims", "plan_audit",
  },
  verify = "swarm_report",
}
