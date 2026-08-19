-- plansup.lua -- durable plans + fleet supervision for multi-agent work.
--
-- The shared SQLite store is the coordination medium: `plans` and `plan_steps`
-- rows are the single source of truth for "what are we doing, who owns each
-- piece, what is left" -- readable and writable by any agent in any session.
-- The planner skill writes these; the supervisor skill reads them; the studio
-- dashboard renders a snapshot of them. docs/agent-planning.md is the design.
--
-- Everything here is pure Lua over an injectable db handle (default bog.db) so
-- tests/plansup.lua can drive it hermetic and deterministic.
--
-- Registered into the tool registry from lua/tools.lua (same pattern as
-- claims.lua) from M.tools:
--   plan_new plan_step plan_wave plan_assign plan_report plan_finish plan_audit
--   fleet_status plan_status swarm_report panel_refresh
--
-- Statuses:
--   plans:      planning | active | done | failed | superseded
--   plan_steps: pending | running | done | failed | skipped
--   "ready" is derived: a pending step whose deps are all done.

local json = require("json")

local M = {}

M.SCHEMA = [[
CREATE TABLE IF NOT EXISTS plans (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL DEFAULT '',
  goal TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'planning',
  owner INTEGER,
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  context TEXT,
  result TEXT
);
CREATE TABLE IF NOT EXISTS plan_steps (
  id INTEGER PRIMARY KEY,
  plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  label TEXT NOT NULL,
  detail TEXT,
  deps TEXT NOT NULL DEFAULT '[]',          -- JSON array of step ids
  status TEXT NOT NULL DEFAULT 'pending',   -- pending|running|done|failed|skipped
  agent_id INTEGER,
  spawned_at INTEGER,
  started_at INTEGER,
  finished_at INTEGER,
  result TEXT,
  error TEXT
);
]]

M.PLAN_STATUSES = { planning = true, active = true, done = true, failed = true, superseded = true }
M.STEP_STATUSES = { pending = true, running = true, done = true, failed = true, skipped = true }

-- A running agent that has not touched its session row in this many seconds is
-- reported as STUCK by the supervisor. Deliberately long: an agent may legally
-- be silent while it waits on the scheduler or on a sub-swarm.
M.STUCK_AFTER = 600

local function now() return os.time() end
local function dbh(db) return db or bog.db end

-- ---------------------------------------------------------------------------
-- schema

function M.ensure(db)
  dbh(db):exec(M.SCHEMA)
end

-- ---------------------------------------------------------------------------
-- plan lifecycle (pure logic, no I/O beyond the db handle)

local function step_index(db, plan_id)
  local rows = dbh(db):query("SELECT id,label FROM plan_steps WHERE plan_id=?", { plan_id }) or {}
  local by_id, by_label = {}, {}
  for _, r in ipairs(rows) do
    by_id[r.id] = r.label
    if r.label and by_label[r.label] == nil then by_label[r.label] = r.id end
  end
  return by_id, by_label
end

local function decode_deps(s)
  local ok, t = pcall(json.decode, s or "[]")
  if ok and type(t) == "table" then return t end
  return {}
end

-- deps may be step ids or step labels (or a mix). Returns (ids, unresolved):
-- ids = resolved step ids (deduped, sorted); unresolved = the inputs that
-- matched nothing, so the caller can warn -- a typo'd label is a bug the
-- planner should hear about at add time, not discover later.
function M.resolve_deps(db, plan_id, deps)
  local by_id, by_label = step_index(db, plan_id)
  local out, unresolved, seen = {}, {}, {}
  for _, d in ipairs(deps or {}) do
    local id = tonumber(d)
    if id and by_id[id] then
      id = id
    elseif type(d) == "string" and by_label[d] then
      id = by_label[d]
    else
      id = nil
    end
    if id then
      if not seen[id] then seen[id] = true; out[#out + 1] = id end
    else
      unresolved[#unresolved + 1] = tostring(d)
    end
  end
  table.sort(out)
  return out, unresolved
end

function M.new_plan(db, goal, opts)
  opts = opts or {}
  local d = dbh(db)
  -- NB: never put nil inside the params array -- db:run sizes it with #, which
  -- stops at the first nil. Use 0/"" sentinels instead.
  local r = d:run(
    "INSERT INTO plans(project,goal,status,owner,created,updated,context) VALUES(?,?,?,?,?,?,?)",
    { opts.project or "", goal or "", "planning", opts.owner or 0, now(), now(), opts.context or "" })
  return r.rowid
end

function M.add_step(db, plan_id, label, detail, deps)
  local d = dbh(db)
  local row = d:query("SELECT COALESCE(MAX(seq),0) AS m FROM plan_steps WHERE plan_id=?", { plan_id })
  local seq = ((row and row[1] and row[1].m) or 0) + 1
  local ids, unresolved = M.resolve_deps(db, plan_id, deps)
  local r = d:run(
    "INSERT INTO plan_steps(plan_id,seq,label,detail,deps,status) VALUES(?,?,?,?,?,?)",
    { plan_id, seq, label or "", detail or "", json.encode(ids), "pending" })
  d:run("UPDATE plans SET updated=? WHERE id=?", { now(), plan_id })
  return r.rowid, unresolved
end

-- pending steps whose deps are all done
function M.ready_steps(db, plan_id)
  local d = dbh(db)
  local rows = d:query("SELECT * FROM plan_steps WHERE plan_id=? AND status='pending' ORDER BY seq", { plan_id }) or {}
  local done = {}
  for _, r in ipairs(d:query("SELECT id FROM plan_steps WHERE plan_id=? AND status='done'", { plan_id }) or {}) do
    done[r.id] = true
  end
  local ready = {}
  for _, r in ipairs(rows) do
    local deps = decode_deps(r.deps)
    local all = true
    for _, dep in ipairs(deps) do
      if not done[dep] then all = false break end
    end
    if all then ready[#ready + 1] = r end
  end
  return ready
end

-- mark the next ready wave 'running'; returns the steps to dispatch
function M.wave(db, plan_id)
  local d = dbh(db)
  local ready = M.ready_steps(db, plan_id)
  local out = {}
  for _, r in ipairs(ready) do
    d:run("UPDATE plan_steps SET status='running', started_at=? WHERE id=? AND plan_id=?", { now(), r.id, plan_id })
    out[#out + 1] = { id = r.id, seq = r.seq, label = r.label, detail = r.detail }
  end
  if #out > 0 then
    d:run("UPDATE plans SET status='active', updated=? WHERE id=?", { now(), plan_id })
  end
  return out
end

-- record which spawned agent owns which step (assignments = {{step_id, agent_id}, ...})
function M.assign(db, plan_id, assignments)
  local d = dbh(db)
  local n = 0
  for _, a in ipairs(assignments or {}) do
    local step_id, agent_id = tonumber(a.step_id or a[1]), tonumber(a.agent_id or a[2])
    if step_id and agent_id then
      d:run("UPDATE plan_steps SET agent_id=?, spawned_at=? WHERE id=? AND plan_id=?",
        { agent_id, now(), step_id, plan_id })
      n = n + 1
    end
  end
  if n > 0 then d:run("UPDATE plans SET updated=? WHERE id=?", { now(), plan_id }) end
  return n
end

-- close out steps with results (results = {{step_id, ok, text?, error?}, ...}).
-- Returns {done, failed, next_ready, total, finished_done}.
function M.report(db, plan_id, results)
  local d = dbh(db)
  local done_n, failed_n = 0, 0
  for _, r in ipairs(results or {}) do
    local step_id = tonumber(r.step_id or r.id)
    if step_id and r.ok ~= nil then
      local status = r.ok and "done" or "failed"
      if status == "done" then done_n = done_n + 1 else failed_n = failed_n + 1 end
      d:run("UPDATE plan_steps SET status=?, finished_at=?, result=?, error=? WHERE id=? AND plan_id=?",
        { status, now(), r.ok and (r.text or "") or "", r.ok and "" or (r.error or r.text or ""), step_id, plan_id })
    end
  end
  local left = d:query("SELECT COUNT(*) AS c FROM plan_steps WHERE plan_id=? AND status IN ('pending','running')", { plan_id })
  local total = d:query("SELECT COUNT(*) AS c FROM plan_steps WHERE plan_id=?", { plan_id })
  local total_n = (total and total[1] and total[1].c) or 0
  local left_n = (left and left[1] and left[1].c) or 0
  local next_ready = #M.ready_steps(db, plan_id)
  d:run("UPDATE plans SET updated=? WHERE id=?", { now(), plan_id })
  -- auto-finish: every step resolved (done or failed) and no step failed
  local failed = d:query("SELECT COUNT(*) AS c FROM plan_steps WHERE plan_id=? AND status='failed'", { plan_id })
  local failed_n_all = (failed and failed[1] and failed[1].c) or 0
  local finished_done = false
  if total_n > 0 and left_n == 0 and failed_n_all == 0 then
    d:run("UPDATE plans SET status='done', updated=? WHERE id=?", { now(), plan_id })
    finished_done = true
  end
  return { done = done_n, failed = failed_n, next_ready = next_ready,
           total = total_n, remaining = left_n, finished_done = finished_done }
end

function M.finish(db, plan_id, status, result)
  local d = dbh(db)
  status = M.PLAN_STATUSES[status] and status or "done"
  d:run("UPDATE plans SET status=?, result=?, updated=? WHERE id=?",
    { status, result or "", now(), plan_id })
  return true
end

-- ---------------------------------------------------------------------------
-- audit (the planner's verify pass)

-- Returns a list of human-readable findings; empty means clean.
function M.audit(db, plan_id)
  local d = dbh(db)
  local out = {}
  if plan_id then
    local p = d:query("SELECT * FROM plans WHERE id=?", { plan_id })
    if not p or #p == 0 then return { "plan " .. tostring(plan_id) .. " does not exist" } end
    local rows = d:query("SELECT * FROM plan_steps WHERE plan_id=? ORDER BY seq", { plan_id }) or {}
    local ids, deps_of, status_of = {}, {}, {}
    for _, r in ipairs(rows) do ids[r.id] = r; deps_of[r.id] = decode_deps(r.deps); status_of[r.id] = r.status end

    for id, deps in pairs(deps_of) do
      for _, dep in ipairs(deps) do
        if dep == id then
          out[#out + 1] = string.format("step %d (%s) depends on itself", id, ids[id].label or "?")
        elseif not ids[dep] then
          out[#out + 1] = string.format("step %d (%s) depends on unknown step %d", id, ids[id].label or "?", dep)
        end
      end
    end

    -- cycles (DFS)
    local visiting, visited = {}, {}
    local function dfs(id, stack)
      if visiting[id] then
        local cyc = {}
        for _, x in ipairs(stack) do
          cyc[#cyc + 1] = tostring(x)
          if x == id then break end
        end
        out[#out + 1] = "dependency cycle: " .. table.concat(cyc, " -> ")
        return
      end
      if visited[id] then return end
      visiting[id] = true
      stack[#stack + 1] = id
      for _, dep in ipairs(deps_of[id] or {}) do dfs(dep, stack) end
      stack[#stack] = nil
      visiting[id] = nil
      visited[id] = true
    end
    for id in pairs(ids) do dfs(id, {}) end

    local counts = { pending = 0, running = 0, done = 0, failed = 0, skipped = 0 }
    for _, r in ipairs(rows) do
      if r.status == "done" then
        for _, dep in ipairs(deps_of[r.id]) do
          if status_of[dep] ~= "done" then
            out[#out + 1] = string.format("step %d (%s) is done but dep %d is %s",
              r.id, r.label or "?", dep, status_of[dep] or "missing")
          end
        end
      end
      if r.status == "running" and not r.agent_id then
        out[#out + 1] = string.format("step %d (%s) is running but has no agent assigned", r.id, r.label or "?")
      end
      if not M.STEP_STATUSES[r.status] then
        out[#out + 1] = string.format("step %d has bad status %q", r.id, r.status)
      end
      counts[r.status] = (counts[r.status] or 0) + 1
    end

    local total = #rows
    local plan_status = p[1].status
    if plan_status == "done" and counts.pending + counts.running > 0 then
      out[#out + 1] = "plan marked done but still has unfinished steps"
    end
    if plan_status == "active" and total > 0 and counts.done + counts.failed + counts.skipped == total then
      out[#out + 1] = "all steps resolved but plan is still 'active' (call plan_finish)"
    end
  else
    local plans = d:query("SELECT id FROM plans ORDER BY id") or {}
    for _, p in ipairs(plans) do
      local f = M.audit(db, p.id)
      for _, x in ipairs(f) do out[#out + 1] = string.format("plan %d: %s", p.id, x) end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- reads (supervision)

function M.plan_list(db, project)
  local d = dbh(db)
  local sql = "SELECT * FROM plans"
  local params = {}
  if project and project ~= "" then
    sql = sql .. " WHERE project=?"
    params[1] = project
  end
  sql = sql .. " ORDER BY id DESC LIMIT 50"
  local plans = d:query(sql, params) or {}
  for _, p in ipairs(plans) do
    local steps = d:query("SELECT status FROM plan_steps WHERE plan_id=?", { p.id }) or {}
    p.step_total = #steps
    p.step_done, p.step_running, p.step_failed, p.step_pending = 0, 0, 0, 0
    for _, s in ipairs(steps) do
      if s.status == "done" then p.step_done = p.step_done + 1
      elseif s.status == "running" then p.step_running = p.step_running + 1
      elseif s.status == "failed" then p.step_failed = p.step_failed + 1
      else p.step_pending = p.step_pending + 1 end
    end
  end
  return plans
end

function M.plan_view(db, plan_id)
  local d = dbh(db)
  local p = d:query("SELECT * FROM plans WHERE id=?", { plan_id })
  if not p or #p == 0 then return nil, nil end
  local steps = d:query("SELECT * FROM plan_steps WHERE plan_id=? ORDER BY seq", { plan_id }) or {}
  return p[1], steps
end

-- Live + recent sub-agents (parent_id set) plus their root coordinators.
-- Each row gains: age (since created), since (since last update), stuck (bool),
-- skills, last (their most recent journal message text).
function M.fleet(db, now_ts)
  local d = dbh(db)
  now_ts = now_ts or now()
  local agents = d:query(
    "SELECT id,title,model,parent_id,status,updated,created,spec FROM sessions "
    .. "WHERE parent_id IS NOT NULL ORDER BY id DESC LIMIT 100") or {}
  local root_ids = {}
  for _, r in ipairs(d:query("SELECT DISTINCT parent_id FROM sessions WHERE parent_id IS NOT NULL") or {}) do
    if r.parent_id then root_ids[r.parent_id] = true end
  end
  local rid_list = {}
  for id in pairs(root_ids) do rid_list[#rid_list + 1] = id end
  if #rid_list > 0 then
    local ph = string.rep("?,", #rid_list):sub(1, -2)
    local roots = d:query(
      "SELECT id,title,model,status,updated,created FROM sessions WHERE id IN (" .. ph .. ")", rid_list) or {}
    for _, r in ipairs(roots) do r.is_root = true; agents[#agents + 1] = r end
  end
  table.sort(agents, function(a, b) return (a.id or 0) < (b.id or 0) end)
  for _, a in ipairs(agents) do
    a.age = now_ts - (a.created or a.updated or now_ts)
    a.since = now_ts - (a.updated or now_ts)
    a.stuck = a.status == "running" and a.since > M.STUCK_AFTER
    local ok, spec = pcall(json.decode, a.spec or "null")
    a.skills = ok and type(spec) == "table" and spec.skills or nil
    local last = d:query(
      "SELECT payload FROM journal WHERE (from_id=? OR to_id=?) AND payload IS NOT NULL "
      .. "ORDER BY ts DESC LIMIT 1", { a.id, a.id })
    a.last = nil
    if last and #last > 0 then
      local ok2, m = pcall(json.decode, last[1].payload)
      if ok2 and type(m) == "table" then a.last = m.text or m.kind or "" end
    end
  end
  return agents
end

-- The full supervision snapshot: fleet + plans + claims + timestamp.
function M.snapshot(db, project)
  local agents = M.fleet(db)
  local plans = M.plan_list(db, project)
  local claims = {}
  local ok, list = pcall(require, "claims")
  if ok and list and list.list then
    local ok2, cl = pcall(list.list)
    if ok2 then claims = cl or {} end
  end
  return { ts = now(), fleet = agents, plans = plans, claims = claims }
end

-- ---------------------------------------------------------------------------
-- text rendering (what the supervisor tools return to the model)

local function dur(s)
  s = tonumber(s) or 0
  if s < 0 then s = 0 end
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  if s < 86400 then return string.format("%dh%02dm", math.floor(s / 3600), math.floor((s % 3600) / 60)) end
  return math.floor(s / 86400) .. "d"
end

function M.format_fleet(db, now_ts)
  local agents = M.fleet(db, now_ts)
  local lines = { "FLEET  (id, status, age, silent, parent, model, skills, last)" }
  local stuck = {}
  for _, a in ipairs(agents) do
    lines[#lines + 1] = string.format(
      "%d  %-8s %-5s %-5s %-6s %-12s %s",
      a.id, a.status or "?", dur(a.age), dur(a.since),
      a.is_root and "root" or tostring(a.parent_id or "-"),
      a.model or "agent",
      a.title and (a.title:gsub("\n", " "):sub(1, 40)) or "")
    if a.stuck then stuck[#stuck + 1] = a.id end
  end
  if #agents == 0 then lines[#lines + 1] = "(no sub-agents)" end
  if #stuck > 0 then
    lines[#lines + 1] = "STUCK (running but silent >" .. dur(M.STUCK_AFTER) .. "): " .. table.concat(stuck, ", ")
  end
  return table.concat(lines, "\n")
end

function M.format_plans(db, project)
  local plans = M.plan_list(db, project)
  local lines = { "PLANS  (id, status, progress, goal, project)" }
  for _, p in ipairs(plans) do
    local total = p.step_total or 0
    local frac = total > 0 and (p.step_done + p.step_failed) .. "/" .. total or "0/0"
    lines[#lines + 1] = string.format("#%d  %-9s %-7s %s  [%s]",
      p.id, p.status or "?", frac, (p.goal or ""):gsub("\n", " "):sub(1, 60),
      p.project and p.project ~= "" and p.project or "no project")
  end
  if #plans == 0 then lines[#lines + 1] = "(no plans)" end
  return table.concat(lines, "\n")
end

-- The supervisor's verdict: findings over fleet + plans + claims.
function M.supervise(db, project)
  local d = dbh(db)
  local findings = {}
  local agents = M.fleet(db)
  local plans = M.plan_list(db, project)

  -- stuck agents
  for _, a in ipairs(agents) do
    if a.stuck then
      findings[#findings + 1] = string.format("STUCK agent %d (%s) running but silent for %s",
        a.id, a.title and (a.title:sub(1, 40)) or "?", dur(a.since))
    end
  end

  -- per-plan: running steps + their agents, failed steps, stalled plans
  for _, p in ipairs(plans) do
    local steps = d:query("SELECT * FROM plan_steps WHERE plan_id=? ORDER BY seq", { p.id }) or {}
    local running, failed = {}, {}
    local any_running_agent = false
    for _, s in ipairs(steps) do
      if s.status == "running" then
        running[#running + 1] = s
        if s.agent_id then any_running_agent = true end
      elseif s.status == "failed" then
        failed[#failed + 1] = s
      end
    end
    if #running > 0 then
      local who = {}
      for _, s in ipairs(running) do
        who[#who + 1] = string.format("%s (agent %s%s)", s.label or s.id,
          s.agent_id or "?", s.agent_id and "" or " unassigned")
      end
      findings[#findings + 1] = string.format("plan #%d running: %s", p.id, table.concat(who, ", "))
    end
    for _, s in ipairs(failed) do
      findings[#findings + 1] = string.format("plan #%d FAILED step %d (%s)%s",
        p.id, s.id, s.label or "?", s.error and (": " .. s.error:sub(1, 80)) or "")
    end
    if p.status == "active" and #running == 0 and (p.step_pending or 0) + (p.step_running or 0) > 0 and not any_running_agent then
      -- active with pending work but nothing running
      local ready = #M.ready_steps(db, p.id)
      if ready == 0 and (p.step_pending or 0) > 0 then
        findings[#findings + 1] = string.format("plan #%d STALLED: %d pending step(s) with no ready work (blocked deps?)",
          p.id, p.step_pending or 0)
      else
        findings[#findings + 1] = string.format("plan #%d idle: %d ready step(s) waiting to be dispatched",
          p.id, ready)
      end
    end
    if p.status == "planning" and #steps > 0 then
      findings[#findings + 1] = string.format("plan #%d still 'planning' with %d steps defined (never dispatched?)",
        p.id, #steps)
    end
  end

  -- claims: files held by agents that are no longer running
  local live = {}
  for _, a in ipairs(agents) do
    if a.status == "running" or a.status == "idle" then live[a.id] = true end
  end
  local ok, claims = pcall(require, "claims")
  if ok and claims and claims.list then
    local ok2, list = pcall(claims.list)
    if ok2 and list then
      for _, c in ipairs(list) do
        if c.writer and not live[c.writer] then
          findings[#findings + 1] = string.format("claim on %s held by dead agent %s", c.path, c.writer)
        end
      end
    end
  end

  if #findings == 0 then
    return "SUPERVISION CLEAR: no stuck agents, no failed steps, no stalled plans."
  end
  return "SUPERVISION FINDINGS (" .. #findings .. "):\n- " .. table.concat(findings, "\n- ")
end

-- ---------------------------------------------------------------------------
-- the studio dashboard panel
--
-- Panels run in a restricted environment (no io, no db): "a panel that wants
-- data should be given it by the host". The host here is panel_refresh, which
-- regenerates ~/.boggart/ui/swarm.lua with a fresh SNAP embedded, and the
-- studio hot-reloads the file when it changes. The draw code below therefore
-- uses only the sandbox-safe subset (math/string/table/os, no require).

local function lua_literal(v, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  if type(v) ~= "table" then return "nil" end
  -- a real array: every key is an integer in 1..#v (empty only if no keys at all)
  local n = #v
  local is_arr = next(v) == nil or n > 0
  if is_arr and n > 0 then
    for k in pairs(v) do
      if type(k) ~= "number" or k < 1 or k > n or math.floor(k) ~= k then is_arr = false break end
    end
  end
  if is_arr then
    local parts = {}
    for _, item in ipairs(v) do parts[#parts + 1] = lua_literal(item, indent + 1) end
    if #parts == 0 then return "{}" end
    return "{\n" .. pad .. "  " .. table.concat(parts, ",\n" .. pad .. "  ") .. "\n" .. pad .. "}"
  end
  local parts = {}
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local vv = v[k]
    if vv ~= nil and type(vv) ~= "function" then
      local key = type(k) == "string" and (string.match(k, "^[%a_][%w_]*$") and k or string.format("[%q]", k)) or "[" .. tostring(k) .. "]"
      parts[#parts + 1] = string.format("%s = %s", key, lua_literal(vv, indent + 1))
    end
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. pad .. "  " .. table.concat(parts, ",\n" .. pad .. "  ") .. "\n" .. pad .. "}"
end

-- Sanitise a snapshot for embedding: strings everywhere nils could hide, and
-- curated for the dashboard -- the fleet shows what needs attention first
-- (stuck, then running, then recent) capped so the panel stays readable; plans
-- show active/planning first, done last.
local function sanitize(snap)
  local out = { ts = snap.ts or 0, fleet = {}, plans = {}, claims = {} }
  local fleet = {}
  for _, a in ipairs(snap.fleet or {}) do
    fleet[#fleet + 1] = {
      id = a.id, status = a.status or "?", age = a.age or 0, since = a.since or 0,
      stuck = a.stuck and true or false, parent = a.parent_id or (a.is_root and "root") or "-",
      title = a.title or "", model = a.model or "agent",
    }
  end
  local rank = function(a)
    if a.stuck then return 0 end
    if a.status == "running" then return 1 end
    if a.status == "idle" then return 2 end
    return 3
  end
  table.sort(fleet, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return (a.id or 0) > (b.id or 0)
  end)
  for i = 1, math.min(#fleet, 24) do out.fleet[#out.fleet + 1] = fleet[i] end

  local plans = {}
  for _, p in ipairs(snap.plans or {}) do
    plans[#plans + 1] = {
      id = p.id, goal = p.goal or "", status = p.status or "?",
      done = p.step_done or 0, total = p.step_total or 0,
      running = p.step_running or 0, failed = p.step_failed or 0,
    }
  end
  local prank = function(p)
    if p.status == "active" then return 0 end
    if p.status == "planning" then return 1 end
    if p.status == "failed" then return 2 end
    return 3
  end
  table.sort(plans, function(a, b)
    local ra, rb = prank(a), prank(b)
    if ra ~= rb then return ra < rb end
    return (a.id or 0) > (b.id or 0)
  end)
  for i = 1, math.min(#plans, 8) do out.plans[#out.plans + 1] = plans[i] end

  for i = 1, math.min(#(snap.claims or {}), 8) do
    local c = snap.claims[i]
    out.claims[#out.claims + 1] = { path = c.path or "", holder = c.writer or "" }
  end
  return out
end

M.PANEL_TEMPLATE = [==[
-- swarm supervision dashboard. Regenerated by the panel_refresh tool with a
-- fresh SNAP; the studio hot-reloads this file when it changes.
local SNAP = __SNAP__

local function dur(s)
  s = tonumber(s) or 0
  if s < 0 then s = 0 end
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  return math.floor(s / 3600) .. "h"
end
local function trunc(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "…"
end
local function bar(x, y, w, frac, colour)
  ctx.rect(x, y, w, 5, style.divider)
  ctx.rect(x, y, math.floor(w * frac), 5, colour)
end

function draw(ctx)
  local y = ctx.y
  local W = ctx.w
  local lh = ctx.line_height

  -- header
  ctx.text("◈ swarm supervision", ctx.x, y, style.text)
  ctx.text(os.date("%H:%M:%S"), ctx.x + W - ctx.text_width("%H:%M:%S"), y, style.dim)
  y = y + lh
  ctx.rect(ctx.x, y, W, 1, style.divider)
  y = y + 4

  -- plans
  ctx.text("plans", ctx.x, y, style.accent)
  y = y + lh
  if #SNAP.plans == 0 then
    ctx.text("(no plans)", ctx.x, y, style.dim)
    y = y + lh
  end
  for _, p in ipairs(SNAP.plans) do
    local frac = p.total > 0 and p.done / p.total or 0
    local col = p.status == "done" and style.good or (p.status == "failed" and style.error or style.accent)
    local head = string.format("#%d %-9s %d/%d  %s", p.id, p.status, p.done, p.total, trunc(p.goal, 40))
    ctx.text(head, ctx.x, y, col)
    bar(ctx.x + ctx.text_width(head) + 8, y + 3, 40, frac, col)
    y = y + lh
  end
  y = y + 2

  -- fleet
  ctx.text("fleet", ctx.x, y, style.accent)
  y = y + lh
  if #SNAP.fleet == 0 then
    ctx.text("(no sub-agents)", ctx.x, y, style.dim)
    y = y + lh
  end
  for _, a in ipairs(SNAP.fleet) do
    local col = a.stuck and style.error or (a.status == "running" and style.good or style.dim)
    local line = string.format("%d  %-8s %-5s %-5s %-5s %s",
      a.id, a.status, dur(a.age), dur(a.since), a.parent, trunc(a.title, 36))
    ctx.text(line, ctx.x, y, col)
    if a.stuck then
      ctx.text("STUCK", ctx.x + W - ctx.text_width("STUCK"), y, style.error)
    end
    y = y + lh
  end
  y = y + 2

  -- claims
  ctx.text("claims", ctx.x, y, style.accent)
  y = y + lh
  if #SNAP.claims == 0 then
    ctx.text("(none)", ctx.x, y, style.dim)
    y = y + lh
  end
  for _, c in ipairs(SNAP.claims) do
    ctx.text(trunc(c.path, 44) .. "  ← " .. c.holder, ctx.x, y, style.dim)
    y = y + lh
  end

  -- footer
  ctx.rect(ctx.x, ctx.y + ctx.h - lh - 8, W, 1, style.divider)
  ctx.text("refresh with panel_refresh · " .. #SNAP.fleet .. " agents · " .. #SNAP.plans .. " plans",
    ctx.x, ctx.y + ctx.h - lh, style.dim)
end
]==]

-- Returns the panel source (also written by the panel_refresh tool).
function M.render_panel(snap)
  local s = sanitize(snap)
  -- gsub, not string.format: the template's own panel code contains %d/%-9s
  -- format specifiers that string.format would try to consume.
  return (M.PANEL_TEMPLATE:gsub("__SNAP__", lua_literal(s)))
end

-- ---------------------------------------------------------------------------
-- tools

local function t(def) return def end

local function need(cond, msg)
  if not cond then error("Tool error: [validation_error] " .. msg, 0) end
end

M.tools = {

  plan_new = t{
    description = "Create a durable plan: INSERT a row into the shared plans table and return its "
      .. "id. Args: goal (required, one line), optional context (extra instructions handed to every "
      .. "step's sub-agent) and project (defaults to the current dir). Use plan_step to add steps, "
      .. "then plan_audit + plan_wave to dispatch. Plans are visible to everyone via plan_status.",
    input_schema = {
      type = "object",
      properties = {
        goal = { type = "string", description = "the goal, one line" },
        context = { type = "string", description = "extra context every step agent should get" },
        project = { type = "string", description = "project label (default current dir)" },
      },
      required = { "goal" },
    },
    run = function(a)
      M.ensure()
      need(type(a.goal) == "string" and a.goal ~= "", "plan_new needs 'goal'")
      local project = a.project
      if not project then
        local ok, root = pcall(function() return require("tools").project_root() end)
        project = ok and root or ""
      end
      local id = M.new_plan(bog.db, a.goal, { context = a.context, project = project })
      return string.format("plan #%d created: %s\nadd steps with plan_step, then plan_audit, then plan_wave.",
        id, a.goal)
    end,
  },

  plan_step = t{
    description = "Add a step to a plan: INSERT a row into plan_steps and return its id. Args: "
      .. "plan_id, label (short imperative), optional detail (the full task text a sub-agent will "
      .. "receive), and deps (array of step ids or labels this step depends on). A step is only "
      .. "dispatched once its deps are all done.",
    input_schema = {
      type = "object",
      properties = {
        plan_id = { type = "integer" },
        label = { type = "string" },
        detail = { type = "string" },
        deps = { type = "array", description = "step ids or labels this step depends on" },
      },
      required = { "plan_id", "label" },
    },
    run = function(a)
      M.ensure()
      local plan_id = tonumber(a.plan_id)
      need(plan_id, "plan_step needs numeric 'plan_id'")
      need(type(a.label) == "string" and a.label ~= "", "plan_step needs 'label'")
      local id, unresolved = M.add_step(bog.db, plan_id, a.label, a.detail, a.deps)
      local out = string.format("step #%d added to plan #%d: %s", id, plan_id, a.label)
      if unresolved and #unresolved > 0 then
        out = out .. "\nWARNING: unresolved deps dropped: " .. table.concat(unresolved, ", ")
          .. " (labels must match an existing step of this plan, or be step ids)"
      end
      return out
    end,
  },

  plan_wave = t{
    description = "Advance a plan by one dispatch wave: mark every ready step (pending with all "
      .. "deps done) as running and return them as lines 'step <id> <seq> <label>' plus their "
      .. "detail. Spawn one sub-agent per returned step, then record the mapping with "
      .. "plan_assign(plan_id, {step_id, agent_id}). Returns '(no ready steps)' when nothing is "
      .. "ready. Respect the spawn agent cap: if spawn refuses, await what is running and retry, "
      .. "or do the work yourself.",
    input_schema = {
      type = "object",
      properties = { plan_id = { type = "integer" } },
      required = { "plan_id" },
    },
    run = function(a)
      M.ensure()
      local plan_id = tonumber(a.plan_id)
      need(plan_id, "plan_wave needs numeric 'plan_id'")
      local wave = M.wave(bog.db, plan_id)
      if #wave == 0 then return "(no ready steps)" end
      local lines = {}
      for _, s in ipairs(wave) do
        lines[#lines + 1] = string.format("step %d  [%d]  %s", s.id, s.seq, s.label)
        if s.detail and s.detail ~= "" then lines[#lines + 1] = "    task: " .. s.detail end
      end
      return string.format("plan #%d wave: %d step(s) now running\n%s", plan_id, #wave, table.concat(lines, "\n"))
    end,
  },

  plan_assign = t{
    description = "Record which spawned agent owns which step, so supervision and the "
      .. "actor_stopped handler can track it. Args: plan_id and assignments = array of "
      .. "{step_id, agent_id} (the ids spawn returned).",
    input_schema = {
      type = "object",
      properties = {
        plan_id = { type = "integer" },
        assignments = {
          type = "array",
          description = "array of {step_id, agent_id}",
          items = { type = "object", properties = {
            step_id = { type = "integer" }, agent_id = { type = "integer" } } },
        },
      },
      required = { "plan_id", "assignments" },
    },
    run = function(a)
      M.ensure()
      local plan_id = tonumber(a.plan_id)
      need(plan_id, "plan_assign needs numeric 'plan_id'")
      local n = M.assign(bog.db, plan_id, a.assignments or {})
      return string.format("plan #%d: %d step(s) assigned to agents", plan_id, n)
    end,
  },

  plan_report = t{
    description = "Close out dispatched steps with results. Args: plan_id and results = array of "
      .. "{step_id, ok (bool), text (what the agent delivered), error?}. ok=true marks the step "
      .. "done; ok=false marks it failed. Returns progress plus how many steps are ready for the "
      .. "next wave. A plan whose steps all resolve done is auto-finished.",
    input_schema = {
      type = "object",
      properties = {
        plan_id = { type = "integer" },
        results = {
          type = "array",
          description = "array of {step_id, ok, text?, error?}",
          items = { type = "object", properties = {
            step_id = { type = "integer" }, ok = { type = "boolean" },
            text = { type = "string" }, error = { type = "string" } } },
        },
      },
      required = { "plan_id", "results" },
    },
    run = function(a)
      M.ensure()
      local plan_id = tonumber(a.plan_id)
      need(plan_id, "plan_report needs numeric 'plan_id'")
      local r = M.report(bog.db, plan_id, a.results or {})
      local out = string.format("plan #%d: %d done, %d failed · %d/%d steps resolved · %d ready next",
        plan_id, r.done, r.failed, r.done + r.failed, r.total, r.next_ready)
      if r.finished_done then out = out .. "\nplan auto-finished as done (all steps resolved, none failed). Call plan_finish to attach a synthesis result." end
      if r.next_ready > 0 then out = out .. "\nrun plan_wave again to dispatch the next wave." end
      return out
    end,
  },

  plan_finish = t{
    description = "Close a plan out. Args: plan_id, optional status (done|failed|superseded; "
      .. "default done) and result (the synthesized answer / outcome note, stored on the plan).",
    input_schema = {
      type = "object",
      properties = {
        plan_id = { type = "integer" },
        status = { type = "string", description = "done | failed | superseded" },
        result = { type = "string", description = "the synthesized outcome" },
      },
      required = { "plan_id" },
    },
    run = function(a)
      M.ensure()
      local plan_id = tonumber(a.plan_id)
      need(plan_id, "plan_finish needs numeric 'plan_id'")
      local status = M.PLAN_STATUSES[a.status] and a.status or "done"
      M.finish(bog.db, plan_id, status, a.result)
      return string.format("plan #%d finished as %s.", plan_id, status)
    end,
  },

  plan_audit = t{
    description = "Verify a plan's integrity. Args: optional plan_id (all plans if omitted). "
      .. "Returns findings (self/unknown deps, cycles, done-with-unmet-deps, running-without-"
      .. "agent, active-plan-with-all-steps-resolved) or '<plan> audit clean'. Run it before "
      .. "dispatching and before finishing a plan; fix everything it flags.",
    input_schema = {
      type = "object",
      properties = { plan_id = { type = "integer" } },
    },
    run = function(a)
      M.ensure()
      local findings = M.audit(bog.db, a.plan_id and tonumber(a.plan_id))
      if #findings == 0 then
        if a.plan_id then return string.format("plan #%d audit clean", tonumber(a.plan_id)) end
        return "no plans to audit (or all clean)"
      end
      return "AUDIT FINDINGS (" .. #findings .. "):\n- " .. table.concat(findings, "\n- ")
    end,
  },

  fleet_status = t{
    description = "Supervision read: every sub-agent (and their roots) in the shared sessions "
      .. "store, with age, time since last activity, stuck flag (running but silent >10m), "
      .. "skills and last message. Use before deciding anything about the swarm.",
    input_schema = { type = "object", properties = {} },
    run = function()
      M.ensure()
      return M.format_fleet(bog.db)
    end,
  },

  plan_status = t{
    description = "Supervision read: all plans with progress (done/running/failed/total), "
      .. "optionally filtered by project.",
    input_schema = {
      type = "object",
      properties = { project = { type = "string" } },
    },
    run = function(a)
      M.ensure()
      return M.format_plans(bog.db, a.project)
    end,
  },

  swarm_report = t{
    description = "The supervision pass: cross-checks fleet + plans + claims and returns "
      .. "findings -- stuck agents, running steps and their agents, failed steps, stalled or "
      .. "undispatched plans, claims held by dead agents -- or 'SUPERVISION CLEAR'. Run this "
      .. "whenever asked to check on the swarm, and cover everything it flags in your answer.",
    input_schema = { type = "object", properties = {} },
    run = function()
      M.ensure()
      return M.supervise(bog.db)
    end,
  },

  panel_refresh = t{
    description = "Refresh the studio swarm-supervision dashboard: regenerate "
      .. "~/.boggart/ui/swarm.lua from a fresh snapshot (fleet + plans + claims + timestamp); "
      .. "the studio hot-reloads the file. Returns the path and time. Safe to run headless.",
    input_schema = { type = "object", properties = {} },
    run = function()
      M.ensure()
      local snap = M.snapshot(bog.db)
      local src = M.render_panel(snap)
      local home = (sys and sys.home and sys.home()) or os.getenv("HOME") or "."
      local dir = home .. "/.boggart/ui"
      if sys and sys.mkdir_p then sys.mkdir_p(dir) end
      local path = dir .. "/swarm.lua"
      local ok, err = pcall(function() return (require("gold").fs or require("gold")).write(path, src) end)
      if not ok then
        -- fall back to raw file write via util if available
        local wok, werr = pcall(function() return bog.util.write_file(path, src) end)
        if not wok then return "Tool error: [runtime] panel write failed: " .. tostring(werr or err) end
      end
      return string.format("panel refreshed: %s (%s, %d agents, %d plans)",
        path, os.date("%H:%M:%S"), #snap.fleet, #snap.plans)
    end,
  },
}

return M
