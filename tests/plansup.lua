-- plansup.lua -- durable plans + fleet supervision (lua/plansup.lua). The plan
-- lifecycle is driven through the pure functions with the REAL (test-isolated)
-- db for correctness; the tools are then exercised through the REAL registry,
-- including a full plan round-trip.
local plansup = require("plansup")
local tools = require("tools")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local db = bog.db
plansup.ensure(db)

-- unique test marker so parallel/interleaved runs never collide
local tag = "plansup-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local function cleanup(plan_id)
  if plan_id then
    db:run("DELETE FROM plan_steps WHERE plan_id=?", { plan_id })
    db:run("DELETE FROM plans WHERE id=?", { plan_id })
  end
end

-- ---- schema: idempotent ----------------------------------------------------
plansup.ensure(db)
local t = db:query("SELECT name FROM sqlite_master WHERE name IN ('plans','plan_steps') ORDER BY name")
eq(#t, 2, "schema creates both tables")

-- ---- lifecycle: new_plan -> add_step (deps by label + id) -> ready/wave -----
local pid = plansup.new_plan(db, tag .. " goal", { project = tag, context = "ctx" })
ok(pid and pid > 0, "new_plan returns an id")

local s1 = plansup.add_step(db, pid, "first", "do the first thing")
local s2 = plansup.add_step(db, pid, "second", "do the second thing", { "first" })
local s3 = plansup.add_step(db, pid, "third", "do the third", { s2 })   -- by id
local s4, dropped = plansup.add_step(db, pid, "orphan", "dep on nothing real", { "first", "nope" })
eq(#dropped, 1, "add_step reports an unresolved dep label")
eq(dropped[1], "nope", "add_step names the unresolved dep")

eq(#plansup.ready_steps(db, pid), 1, "only first step is ready initially")
eq(plansup.ready_steps(db, pid)[1].id, s1, "first step is ready")
eq(plansup.ready_steps(db, pid)[1].detail, "do the first thing", "ready step carries detail")

local _, steps = plansup.plan_view(db, pid)
eq(#steps, 4, "four steps added")

-- ---- wave marks running; ready excludes running -----------------------------
local wave = plansup.wave(db, pid)
eq(#wave, 1, "wave dispatches one step")
eq(wave[1].id, s1, "wave dispatches the ready step")
eq(#plansup.ready_steps(db, pid), 0, "no ready steps while first is running")
local p = db:query("SELECT status FROM plans WHERE id=?", { pid })
eq(p[1].status, "active", "plan becomes active on first wave")

-- ---- assign + report: ok -> done; failed dep blocks its dependents ----------
eq(plansup.assign(db, pid, { { step_id = s1, agent_id = 424242 } }), 1, "assign records agent")
plansup.assign(db, pid, { { step_id = s2, agent_id = 999 } })
local r = plansup.report(db, pid, {
  { step_id = s1, ok = true, text = "first done" },
  { step_id = s2, ok = false, error = "boom" },
})
eq(r.done, 1, "report marks one done")
eq(r.failed, 1, "report marks one failed")
eq(r.total, 4, "report sees total steps")
eq(r.next_ready, 1, "one step ready next (s4: dep s1 done; s3 blocked by failed s2)")
local ready = plansup.ready_steps(db, pid)
eq(#ready, 1, "exactly one ready step after the first report")
eq(ready[1].id, s4, "the ready step is the one whose dep is done, not the failed one's")

-- ---- audit: finds the problems we made --------------------------------------
-- corrupt s4's deps to point at a nonexistent step -> unknown-dep finding
db:run("UPDATE plan_steps SET deps=? WHERE id=?", { "[999999]", s4 })
local joined = table.concat(plansup.audit(db, pid), "|")
ok(joined:find("unknown step 999999") ~= nil, "audit flags an unknown dep")
ok(joined:find("orphan") ~= nil, "audit names the step with the bad dep")

-- now build a CLEAN plan and check audit is silent on it
local pid2 = plansup.new_plan(db, tag .. " clean", { project = tag })
local c1 = plansup.add_step(db, pid2, "a", "A")
local c2 = plansup.add_step(db, pid2, "b", "B", { c1 })
plansup.wave(db, pid2)
plansup.assign(db, pid2, { { step_id = c1, agent_id = 7 } })
plansup.report(db, pid2, { { step_id = c1, ok = true, text = "A" } })
plansup.wave(db, pid2)
plansup.assign(db, pid2, { { step_id = c2, agent_id = 8 } })
plansup.report(db, pid2, { { step_id = c2, ok = true, text = "B" } })
eq(#plansup.audit(db, pid2), 0, "clean plan audits clean")
local p2 = db:query("SELECT status FROM plans WHERE id=?", { pid2 })
eq(p2[1].status, "done", "plan auto-finishes done when all steps resolve")

-- cycle plan: x -> y -> x
local pid3 = plansup.new_plan(db, tag .. " cycle", { project = tag })
local d1 = plansup.add_step(db, pid3, "x", "X")
local d2 = plansup.add_step(db, pid3, "y", "Y", { d1 })
db:run("UPDATE plan_steps SET deps=? WHERE id=?", { "[" .. d2 .. "]", d1 })
-- done-with-unmet-dep: force y done while x is still pending
db:run("UPDATE plan_steps SET status='done' WHERE id=?", { d2 })
local f3 = table.concat(plansup.audit(db, pid3), "|")
ok(f3:find("cycle") ~= nil, "audit detects a dependency cycle")
ok(f3:find("done but dep") ~= nil, "audit flags a done step with an unmet dep")

-- running-without-agent plan
local pid4 = plansup.new_plan(db, tag .. " runnernot", { project = tag })
plansup.add_step(db, pid4, "z", "Z")
plansup.wave(db, pid4) -- running, never assigned
ok(table.concat(plansup.audit(db, pid4), "|"):find("running but has no agent") ~= nil,
  "audit flags running-without-agent")

-- ---- reads: plan_list carries counts ----------------------------------------
local list = plansup.plan_list(db, tag)
eq(#list, 4, "plan_list filtered by project returns our plans")
for _, p in ipairs(list) do
  if p.id == pid2 then
    eq(p.step_done, 2, "plan_list counts done steps")
    eq(p.step_total, 2, "plan_list counts total steps")
  end
end

-- ---- fleet: fake sub-agent appears; stuck detection -------------------------
db:run("INSERT INTO sessions(id,title,model,parent_id,status,created,updated,spec) "
  .. "VALUES(?,?,?,?,?,?,?,?)",
  { 900000, "coordinator", "agent", nil, "running", os.time() - 3600, os.time() - 60,
    '{"agent":"coordinator","skills":["orchestrate"]}' })
db:run("INSERT INTO sessions(id,title,model,parent_id,status,created,updated,spec) "
  .. "VALUES(?,?,?,?,?,?,?,?)",
  { 900001, "stuck worker", "agent", 900000, "running", os.time() - 2000, os.time() - 2000,
    '{"agent":"agent","skills":["core"]}' })
local fleet = plansup.fleet(db)
local found, root = nil, nil
for _, a in ipairs(fleet) do
  if a.id == 900001 then found = a end
  if a.id == 900000 then root = a end
end
ok(found ~= nil, "fleet lists a sub-agent")
ok(found.stuck, "long-silent running agent flagged stuck")
ok(found.parent_id == 900000, "sub-agent records its parent")
ok(root ~= nil, "fleet includes the parent root session")
ok(root.is_root, "fleet marks the root session as root")
db:run("DELETE FROM sessions WHERE id IN (900001, 900000)")

-- ---- supervise: sees a failed step and a stalled plan ------------------------
local sup = plansup.supervise(db, tag)
ok(sup:find("plan #" .. pid) ~= nil, "supervise reports on our plans")
ok(sup:find("FAILED step") ~= nil, "supervise flags failed steps")
ok(sup:find("STALLED") ~= nil or sup:find("still 'planning'") ~= nil,
  "supervise flags an undispatched/stalled plan")

-- ---- snapshot + panel --------------------------------------------------------
local snap = plansup.snapshot(db, tag)
ok(type(snap.fleet) == "table" and type(snap.plans) == "table" and type(snap.claims) == "table",
  "snapshot has fleet/plans/claims")
ok(type(snap.ts) == "number", "snapshot has a timestamp")
local src = plansup.render_panel(snap)
ok(src:find("function draw%(ctx%)") ~= nil, "render_panel emits a draw function")
ok(src:find("SNAP") ~= nil, "render_panel embeds the snapshot")
ok(src:find("swarm supervision") ~= nil, "render_panel has the dashboard header")
-- the embedded snapshot must be loadable Lua
local snap_lit = src:match("local SNAP = (.-)\n\nlocal function dur")
ok(snap_lit ~= nil, "render_panel snapshot literal is findable")
if snap_lit then
  local chunk, err = load("return " .. snap_lit)
  ok(chunk ~= nil, "embedded snapshot is valid Lua (" .. tostring(err) .. ")")
  if chunk then
    local lit = chunk()
    eq(type(lit), "table", "embedded snapshot loads as a table")
    eq(#lit.plans, 4, "embedded snapshot carries the plans")
  end
end

-- ---- wiring: tools registered in the real registry ---------------------------
for _, name in ipairs({ "plan_new", "plan_step", "plan_wave", "plan_assign",
                        "plan_report", "plan_finish", "plan_audit",
                        "fleet_status", "plan_status", "swarm_report", "panel_refresh" }) do
  ok(tools.registry[name] ~= nil, name .. " is registered")
end

-- ---- end to end through the REAL registry ------------------------------------
local out = tools.run("plan_new", { goal = tag .. " e2e", project = tag })
local e2e_pid = tonumber(out:match("plan #(%d+)"))
ok(e2e_pid ~= nil, "plan_new tool creates a plan")
local step_out = tools.run("plan_step", { plan_id = e2e_pid, label = "solo", detail = "do it" })
ok(step_out:find("step #%d+ added") ~= nil, "plan_step tool adds a step")
local aout = tools.run("plan_audit", { plan_id = e2e_pid })
ok(aout:find("audit clean") ~= nil, "plan_audit tool reports clean on a fresh plan")
local wout = tools.run("plan_wave", { plan_id = e2e_pid })
local sid = tonumber(wout:match("step (%d+)"))
ok(sid ~= nil, "plan_wave tool returns the ready step id")
tools.run("plan_assign", { plan_id = e2e_pid, assignments = { { step_id = sid, agent_id = 424243 } } })
local rout = tools.run("plan_report", { plan_id = e2e_pid,
  results = { { step_id = sid, ok = true, text = "did it" } } })
ok(rout:find("1 done") ~= nil, "plan_report tool reports the done count")
ok(rout:find("auto%-finished") ~= nil, "plan_report tool auto-finishes a fully-resolved plan")
local fout = tools.run("plan_finish", { plan_id = e2e_pid, result = "synthesis" })
ok(fout:find("finished as done") ~= nil, "plan_finish tool closes the plan")
local st = tools.run("plan_status", { project = tag })
ok(st:find("#" .. e2e_pid) ~= nil, "plan_status tool lists the plan")
local fs = tools.run("fleet_status")
ok(fs:find("FLEET") ~= nil, "fleet_status tool renders the fleet")
local sr = tools.run("swarm_report")
ok(sr:find("SUPERVISION") ~= nil, "swarm_report tool renders a verdict")

-- cleanup our test plans
for _, id in ipairs({ pid, pid2, pid3, pid4, e2e_pid }) do cleanup(id) end

io.write(string.format("plansup: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
