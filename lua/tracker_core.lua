-- tracker_core.lua -- boggart's built-in tracker, and the `tracker` tool.
--
-- Modelled on ai-grind's devtools-mcp tracker and LLM Station's native tracker
-- (llm-station docs/architecture/design-native-tracker.md, which is the spec
-- both follow): projects with atomically allocated PROJ-123 keys, a task
-- hierarchy (6 levels) with kinds, statuses and priorities, acceptance
-- criteria linked to tests with a strict/advisory close gate, cycle-checked
-- dependencies with a ready/blocked/waiting resolver and parallel layers, tags
-- with auto-tag rules, commit links, and bounded query views.
--
-- ONE tool, `tracker`, with `noun` + `action` and flat parameters -- the exact
-- surface LLM Station's `tracker` tool exposes. That is the point: with the
-- station backend selected, a call is passed through over ZMQ unchanged, so
-- the model (and every skill) uses one vocabulary whichever store answers.
--   /tracker backend native|station     (kv config.tracker.backend)
-- The native store is SQLite in boggart.db (trk_* tables).
--
-- Error contract (upstream's): domain violations return "Error: <msg>"
-- strings, never a raise; missing arguments name what is missing; unknown
-- actions list the valid set.
local M = {}

M.KINDS = { epic = true, story = true, task = true, subtask = true, spike = true, test = true }
M.STATUSES = { open = true, in_progress = true, blocked = true, in_review = true, done = true, cancelled = true }
M.STATUS_ORDER = { "open", "in_progress", "blocked", "in_review", "done", "cancelled" }
M.CLOSED = { done = true, cancelled = true }
M.CHILD_KIND = { epic = "story", story = "task", task = "subtask", subtask = "subtask", spike = "subtask", test = "subtask" }
M.MAX_DEPTH = 5            -- depth 0..5: six levels
M.MAX_DEPS = 50
M.MAX_BREAKDOWN = 20
M.MAX_LIMIT, M.DEFAULT_LIMIT = 200, 50
M.MAX_SCAN = 500

local function now() return os.time() end
local function err(msg) return "Error: " .. msg end
local function db() return bog.db end

local function uid()
  local t = {}
  for i = 1, 16 do t[i] = string.format("%02x", math.random(0, 255)) end
  return table.concat(t)
end

-- ---- schema --------------------------------------------------------------------
local ready = false
function M.ensure_schema()
  if ready then return true end
  if not (bog and bog.db) then return nil, "store not open" end
  local d = db()
  for _, sql in ipairs{
    [[CREATE TABLE IF NOT EXISTS trk_projects (
        key TEXT PRIMARY KEY, uid TEXT, name TEXT NOT NULL, description TEXT DEFAULT '',
        close_policy TEXT NOT NULL DEFAULT 'advisory', next_seq INTEGER NOT NULL DEFAULT 1,
        created INTEGER, updated INTEGER)]],
    [[CREATE TABLE IF NOT EXISTS trk_tasks (
        id INTEGER PRIMARY KEY, uid TEXT UNIQUE, key TEXT UNIQUE NOT NULL, project TEXT NOT NULL,
        seq INTEGER NOT NULL, parent_id INTEGER, depth INTEGER NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT 'task', status TEXT NOT NULL DEFAULT 'open',
        priority INTEGER NOT NULL DEFAULT 3, sort_order REAL NOT NULL DEFAULT 0,
        title TEXT NOT NULL, description TEXT DEFAULT '', recipe TEXT DEFAULT '',
        created INTEGER, updated INTEGER, closed_ts INTEGER)]],
    [[CREATE INDEX IF NOT EXISTS trk_tasks_project ON trk_tasks(project, status)]],
    [[CREATE INDEX IF NOT EXISTS trk_tasks_parent ON trk_tasks(parent_id)]],
    [[CREATE TABLE IF NOT EXISTS trk_criteria (
        id INTEGER PRIMARY KEY, uid TEXT, task_id INTEGER NOT NULL, text TEXT NOT NULL,
        test_ref TEXT DEFAULT '', last_result TEXT DEFAULT '', last_run_at INTEGER, created INTEGER)]],
    [[CREATE INDEX IF NOT EXISTS trk_criteria_task ON trk_criteria(task_id)]],
    [[CREATE TABLE IF NOT EXISTS trk_deps (
        task_id INTEGER NOT NULL, depends_on INTEGER NOT NULL, PRIMARY KEY (task_id, depends_on))]],
    [[CREATE TABLE IF NOT EXISTS trk_tags (
        task_id INTEGER NOT NULL, tag TEXT NOT NULL, PRIMARY KEY (task_id, tag))]],
    [[CREATE TABLE IF NOT EXISTS trk_tag_rules (
        uid TEXT PRIMARY KEY, tag TEXT NOT NULL, match_kind TEXT DEFAULT '', match_regex TEXT DEFAULT '',
        match_parent_kind TEXT DEFAULT '', project TEXT DEFAULT '', created INTEGER)]],
    [[CREATE TABLE IF NOT EXISTS trk_issues (
        task_id INTEGER NOT NULL, repo TEXT NOT NULL, number INTEGER NOT NULL, url TEXT DEFAULT '',
        state TEXT DEFAULT '', remote_title TEXT DEFAULT '', synced_at INTEGER,
        PRIMARY KEY (task_id, repo))]],
    [[CREATE TABLE IF NOT EXISTS trk_commits (
        task_id INTEGER NOT NULL, repo TEXT NOT NULL, commit_hash TEXT NOT NULL, message TEXT DEFAULT '',
        linked_at INTEGER, PRIMARY KEY (task_id, commit_hash))]],
  } do d:run(sql) end
  ready = true
  return true
end

-- ---- lookups -------------------------------------------------------------------
local function q(sql, p) return db():query(sql, p or {}) or {} end
local function one(sql, p) return q(sql, p)[1] end
local function run(sql, p) return db():run(sql, p or {}) end

local function norm_key(k) return type(k) == "string" and (k:upper():gsub("%s+", "")) or nil end
local function project_row(key) return key and one("SELECT * FROM trk_projects WHERE key = ?", { norm_key(key) }) end
local function task_row(key) return key and one("SELECT * FROM trk_tasks WHERE key = ?", { norm_key(key) }) end
local function task_by_id(id) return one("SELECT * FROM trk_tasks WHERE id = ?", { id }) end
M.task_row, M.project_row = task_row, project_row

local function int(v, default)
  local n = tonumber(v)
  if not n then return default end
  return math.floor(n)
end
local function truthy(v) return v == true or v == "true" or v == "1" or v == 1 end

-- ---- rendering -----------------------------------------------------------------
local function task_line(t)
  return string.format("- `%s` [%s/%s] P%d %s", t.key, t.kind, t.status, t.priority, t.title)
end
M.task_line = task_line

-- ---- projects -------------------------------------------------------------------
local P = {}
function P.create(a)
  local key = norm_key(a.key)
  if not key or key == "" then return err("project create needs `key`") end
  if not key:match("^[A-Z][A-Z0-9]*$") or #key > 12 then
    return err("project key must be uppercase letters/digits, starting with a letter, <=12 chars")
  end
  if project_row(key) then return err("project '" .. key .. "' already exists") end
  local policy = a.close_policy ~= nil and a.close_policy ~= "" and a.close_policy or "advisory"
  if policy ~= "advisory" and policy ~= "strict" then return err("close_policy must be advisory|strict") end
  run("INSERT INTO trk_projects(key,uid,name,description,close_policy,next_seq,created,updated) VALUES(?,?,?,?,?,1,?,?)",
    { key, uid(), (a.name ~= nil and a.name ~= "" and a.name) or a.title or key, a.description or "", policy, now(), now() })
  return "Created project `" .. key .. "` (" .. policy .. ")"
end
function P.list()
  local rows = q("SELECT * FROM trk_projects ORDER BY key")
  local out = { "**Projects (" .. #rows .. ")**" }
  for _, p in ipairs(rows) do
    out[#out + 1] = string.format("- `%s` %s — policy=%s, next=`%s-%d`", p.key, p.name, p.close_policy, p.key, p.next_seq)
  end
  return table.concat(out, "\n")
end
function P.get(a)
  local p = project_row(a.key or a.project)
  if not p then return err("no such project '" .. tostring(a.key or a.project) .. "'") end
  local out = { string.format("**`%s` %s**", p.key, p.name) }
  if p.description ~= "" then out[#out + 1] = p.description end
  out[#out + 1] = string.format("\npolicy: %s · next: `%s-%d`\n", p.close_policy, p.key, p.next_seq)
  for _, r in ipairs(q([[SELECT kind, status, count(*) AS n FROM trk_tasks WHERE project = ?
                         GROUP BY kind, status ORDER BY kind, status]], { p.key })) do
    out[#out + 1] = string.format("- %s: %s=%d", r.kind, r.status, r.n)
  end
  return table.concat(out, "\n")
end
function P.set_policy(a)
  local p = project_row(a.key or a.project)
  if not p then return err("no such project") end
  if a.close_policy ~= "advisory" and a.close_policy ~= "strict" then return err("close_policy must be advisory|strict") end
  run("UPDATE trk_projects SET close_policy = ?, updated = ? WHERE key = ?", { a.close_policy, now(), p.key })
  return "Project `" .. p.key .. "` policy=" .. a.close_policy
end

-- ---- tag rules (applied at create) -----------------------------------------------
local function rule_matches(r, t, parent)
  if r.project ~= "" and r.project ~= t.project then return false end
  local any = false
  if r.match_kind ~= "" then any = true; if r.match_kind ~= t.kind then return false end end
  if r.match_parent_kind ~= "" then
    any = true
    if not parent or parent.kind ~= r.match_parent_kind then return false end
  end
  if r.match_regex ~= "" then
    any = true
    local ok, s = pcall(gold.re.find, (t.title or "") .. "\n" .. (t.description or ""), r.match_regex, "i")
    if not (ok and s) then return false end
  end
  return any
end

local function apply_rules(t, parent)
  local added = {}
  for _, r in ipairs(q("SELECT * FROM trk_tag_rules")) do
    if rule_matches(r, t, parent) then
      run("INSERT OR IGNORE INTO trk_tags(task_id, tag) VALUES(?, ?)", { t.id, r.tag })
      added[#added + 1] = r.tag
    end
  end
  return added
end

-- ---- tasks ------------------------------------------------------------------------
local T = {}

local function next_sort(project, parent_id)
  local r = parent_id and one("SELECT max(sort_order) AS m FROM trk_tasks WHERE parent_id = ?", { parent_id })
    or one("SELECT max(sort_order) AS m FROM trk_tasks WHERE project = ? AND parent_id IS NULL", { project })
  return ((r and tonumber(r.m)) or 0) + 1
end

local function insert_task(p, a, parent)
  local kind = (a.kind ~= nil and a.kind ~= "") and a.kind or (parent and M.CHILD_KIND[parent.kind]) or "task"
  if not M.KINDS[kind] then return nil, "kind must be epic|story|task|subtask|spike|test" end
  local depth = parent and (parent.depth + 1) or 0
  if depth > M.MAX_DEPTH then return nil, "hierarchy is capped at " .. (M.MAX_DEPTH + 1) .. " levels" end
  -- tracker.classify on the tier ladder (opt-in): fill a missing kind/priority.
  -- A caller's own value always wins; nil leaves the defaults.
  local sug = bog and bog.ladder_sites and bog.ladder_sites.tracker_classify(a, parent)
  if sug then
    if sug.kind and M.KINDS[sug.kind] and (a.kind == nil or a.kind == "") and not parent then kind = sug.kind end
    if sug.priority and (a.priority == nil or a.priority == "") then a = setmetatable({ priority = sug.priority }, { __index = a }) end
  end
  local prio = int(a.priority, 3)
  if prio < 1 or prio > 5 then return nil, "priority must be 1..5" end
  local title = a.title
  if type(title) ~= "string" or title:match("^%s*$") then return nil, "task needs a `title`" end
  -- Atomic key allocation: one UPDATE ... RETURNING, so two processes on the
  -- same store (TUI + studio) can never hand out the same key.
  local s = one("UPDATE trk_projects SET next_seq = next_seq + 1, updated = ? WHERE key = ? RETURNING next_seq - 1 AS seq",
    { now(), p.key })
  if not s then return nil, "no such project '" .. p.key .. "'" end
  local key = p.key .. "-" .. s.seq
  -- NULLIF(?,0): the binder walks a Lua array, so a nil mid-array is unsafe;
  -- 0 (never a real rowid) stands for NULL.
  local r = run([[INSERT INTO trk_tasks(uid,key,project,seq,parent_id,depth,kind,status,priority,sort_order,
                   title,description,recipe,created,updated) VALUES(?,?,?,?,NULLIF(?,0),?,?,'open',?,?,?,?,?,?,?)]],
    { uid(), key, p.key, s.seq, parent and parent.id or 0, depth, kind, prio,
      next_sort(p.key, parent and parent.id), title, a.description or "", a.recipe or "", now(), now() })
  local t = task_by_id(r.rowid)
  apply_rules(t, parent)
  return t
end

function T.create(a)
  local p = project_row(a.project)
  if not p then return err("task create needs an existing `project` (got " .. tostring(a.project) .. ")") end
  local parent
  if a.parent and a.parent ~= "" then
    parent = task_row(a.parent)
    if not parent then return err("no such parent '" .. a.parent .. "'") end
    if parent.project ~= p.key then return err("parent must be in the same project") end
  end
  local t, e = insert_task(p, a, parent)
  if not t then return err(e) end
  local tags = q("SELECT tag FROM trk_tags WHERE task_id = ? ORDER BY tag", { t.id })
  local line = "Created " .. task_line(t):sub(3)
  if #tags > 0 then
    local n = {}; for _, x in ipairs(tags) do n[#n + 1] = x.tag end
    line = line .. "  (auto-tags: " .. table.concat(n, ", ") .. ")"
  end
  return line
end

function T.get(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local out = { string.format("**`%s` %s**", t.key, t.title),
    string.format("kind=%s · status=%s · priority=P%d · depth=%d", t.kind, t.status, t.priority, t.depth) }
  if t.parent_id then
    local pt = task_by_id(t.parent_id)
    if pt then out[#out + 1] = "parent: `" .. pt.key .. "` " .. pt.title end
  end
  if t.recipe ~= "" then out[#out + 1] = "recipe: " .. t.recipe end
  if t.description ~= "" then out[#out + 1] = "\n" .. t.description end
  local kids = q("SELECT * FROM trk_tasks WHERE parent_id = ? ORDER BY sort_order", { t.id })
  if #kids > 0 then
    out[#out + 1] = "\n**Children (" .. #kids .. ")**"
    for _, k in ipairs(kids) do out[#out + 1] = task_line(k) end
  end
  local crit = q("SELECT * FROM trk_criteria WHERE task_id = ? ORDER BY id", { t.id })
  if #crit > 0 then
    out[#out + 1] = "\n**Acceptance criteria**"
    for _, c in ipairs(crit) do out[#out + 1] = M.criterion_line(c) end
  end
  local tags = q("SELECT tag FROM trk_tags WHERE task_id = ? ORDER BY tag", { t.id })
  if #tags > 0 then
    local n = {}; for _, x in ipairs(tags) do n[#n + 1] = x.tag end
    out[#out + 1] = "\ntags: " .. table.concat(n, ", ")
  end
  local deps = q([[SELECT t.key, t.status FROM trk_deps d JOIN trk_tasks t ON t.id = d.depends_on
                   WHERE d.task_id = ? ORDER BY t.key]], { t.id })
  if #deps > 0 then
    local n = {}; for _, x in ipairs(deps) do n[#n + 1] = "`" .. x.key .. "` (" .. x.status .. ")" end
    out[#out + 1] = "depends on: " .. table.concat(n, ", ")
  end
  local commits = q("SELECT * FROM trk_commits WHERE task_id = ? ORDER BY linked_at", { t.id })
  if #commits > 0 then
    out[#out + 1] = "\n**Commits**"
    for _, c in ipairs(commits) do out[#out + 1] = "- " .. c.commit_hash:sub(1, 10) .. " " .. (c.message or "") end
  end
  return table.concat(out, "\n")
end

function T.update(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local sets, vals = {}, {}
  local function set(col, v) sets[#sets + 1] = col .. " = ?"; vals[#vals + 1] = v end
  if a.title ~= nil and a.title ~= "" then set("title", a.title) end
  if a.description ~= nil then set("description", a.description) end
  if a.kind ~= nil and a.kind ~= "" then
    if not M.KINDS[a.kind] then return err("kind must be epic|story|task|subtask|spike|test") end
    set("kind", a.kind)
  end
  if a.priority ~= nil and a.priority ~= "" then
    local p = int(a.priority); if not p or p < 1 or p > 5 then return err("priority must be 1..5") end
    set("priority", p)
  end
  if a.recipe ~= nil then set("recipe", a.recipe) end
  if #sets == 0 then return err("task update needs one of title/description/kind/priority/recipe") end
  set("updated", now()); vals[#vals + 1] = t.id
  run("UPDATE trk_tasks SET " .. table.concat(sets, ", ") .. " WHERE id = ?", vals)
  return "Updated " .. task_line(task_by_id(t.id)):sub(3)
end

-- depth of every descendant must stay within the cap after a move
local function subtree(id, out)
  out = out or {}
  for _, k in ipairs(q("SELECT id, depth FROM trk_tasks WHERE parent_id = ?", { id })) do
    out[#out + 1] = k; subtree(k.id, out)
  end
  return out
end

function T.move(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local parent, new_parent_id = nil, t.parent_id
  if truthy(a.to_root) then new_parent_id = nil
  elseif a.parent and a.parent ~= "" then
    parent = task_row(a.parent)
    if not parent then return err("no such parent '" .. a.parent .. "'") end
    if parent.project ~= t.project then return err("parent must be in the same project") end
    if parent.id == t.id then return err("a task cannot be its own parent") end
    for _, d in ipairs(subtree(t.id)) do
      if d.id == parent.id then return err("cannot move a task under its own descendant") end
    end
    new_parent_id = parent.id
  elseif not (a.before and a.before ~= "") then
    return err("task move needs `parent`, `to_root` or `before`")
  end
  if new_parent_id and not parent then parent = task_by_id(new_parent_id) end
  local new_depth = parent and (parent.depth + 1) or 0
  local shift = new_depth - t.depth
  local deepest = new_depth
  for _, d in ipairs(subtree(t.id)) do deepest = math.max(deepest, d.depth + shift) end
  if deepest > M.MAX_DEPTH then return err("move would exceed " .. (M.MAX_DEPTH + 1) .. " levels") end

  local order
  if a.before and a.before ~= "" then
    local b = task_row(a.before)
    if not b then return err("no such sibling '" .. a.before .. "'") end
    if (b.parent_id or 0) ~= (new_parent_id or 0) or b.project ~= t.project then
      return err("`before` must be a sibling at the destination")
    end
    local prev = new_parent_id
      and one("SELECT max(sort_order) AS m FROM trk_tasks WHERE parent_id = ? AND sort_order < ? AND id <> ?", { new_parent_id, b.sort_order, t.id })
      or one("SELECT max(sort_order) AS m FROM trk_tasks WHERE project = ? AND parent_id IS NULL AND sort_order < ? AND id <> ?", { t.project, b.sort_order, t.id })
    local lo = (prev and tonumber(prev.m)) or (b.sort_order - 1)
    order = (lo + b.sort_order) / 2
  else
    order = next_sort(t.project, new_parent_id)
  end
  run("UPDATE trk_tasks SET parent_id = NULLIF(?,0), depth = ?, sort_order = ?, updated = ? WHERE id = ?",
    { new_parent_id or 0, new_depth, order, now(), t.id })
  if shift ~= 0 then
    for _, d in ipairs(subtree(t.id)) do run("UPDATE trk_tasks SET depth = ? WHERE id = ?", { d.depth + shift, d.id }) end
  end
  return "Moved " .. task_line(task_by_id(t.id)):sub(3) .. " (depth " .. new_depth .. ")"
end

function T.breakdown(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local titles = {}
  for raw in tostring(a.subtasks or ""):gmatch("[^\n;]+") do
    local s = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" then titles[#titles + 1] = s end
  end
  if #titles == 0 then return err("task breakdown needs `subtasks` (newline- or ;-separated titles)") end
  if #titles > M.MAX_BREAKDOWN then return err("at most " .. M.MAX_BREAKDOWN .. " subtasks per breakdown") end
  -- Checked before any child is written, so a refused breakdown is an error,
  -- not a half-done one.
  if t.depth + 1 > M.MAX_DEPTH then return err("hierarchy is capped at " .. (M.MAX_DEPTH + 1) .. " levels") end
  local p = project_row(t.project)
  local out = { "Broke `" .. t.key .. "` into " .. #titles .. ":" }
  for _, title in ipairs(titles) do
    local c, e = insert_task(p, { title = title, kind = a.kind }, t)
    if not c then return table.concat(out, "\n") .. "\n" .. err(e) end
    out[#out + 1] = task_line(c)
  end
  return table.concat(out, "\n")
end

-- ---- criteria ------------------------------------------------------------------------
function M.criterion_line(c)
  local mark = c.last_result == "pass" and "[x]" or (c.last_result == "fail" and "[!]" or "[ ]")
  return string.format("- %s #%d %s%s", mark, c.id, c.text, c.test_ref ~= "" and ("  (" .. c.test_ref .. ")") or "")
end

local C = {}
function C.add(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  if type(a.text) ~= "string" or a.text:match("^%s*$") then return err("criteria add needs `text`") end
  local r = run("INSERT INTO trk_criteria(uid,task_id,text,test_ref,created) VALUES(?,?,?,?,?)",
    { uid(), t.id, a.text, a.test_ref or "", now() })
  return "Added criterion #" .. r.rowid .. " to `" .. t.key .. "`"
end
local function crit(a)
  local id = int(a.criterion_id)
  if not id then return nil, err("needs `criterion_id`") end
  local c = one("SELECT * FROM trk_criteria WHERE id = ?", { id })
  if not c then return nil, err("no such criterion #" .. id) end
  return c
end
function C.update(a)
  local c, e = crit(a); if not c then return e end
  run("UPDATE trk_criteria SET text = ?, test_ref = ? WHERE id = ?",
    { (a.text ~= nil and a.text ~= "") and a.text or c.text, a.test_ref ~= nil and a.test_ref or c.test_ref, c.id })
  return "Updated " .. M.criterion_line(one("SELECT * FROM trk_criteria WHERE id = ?", { c.id })):sub(3)
end
function C.record(a)
  local c, e = crit(a); if not c then return e end
  if a.result ~= "pass" and a.result ~= "fail" then return err("result must be pass|fail") end
  run("UPDATE trk_criteria SET last_result = ?, last_run_at = ? WHERE id = ?", { a.result, now(), c.id })
  return "Recorded " .. a.result .. " for criterion #" .. c.id
end
function C.remove(a)
  local c, e = crit(a); if not c then return e end
  run("DELETE FROM trk_criteria WHERE id = ?", { c.id })
  return "Removed criterion #" .. c.id
end
function C.list(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local rows = q("SELECT * FROM trk_criteria WHERE task_id = ? ORDER BY id", { t.id })
  if #rows == 0 then return "`" .. t.key .. "` has no acceptance criteria" end
  local out = { "**`" .. t.key .. "` acceptance criteria**" }
  for _, c in ipairs(rows) do out[#out + 1] = M.criterion_line(c) end
  return table.concat(out, "\n")
end

-- ---- status (the close gate) ----------------------------------------------------------
-- Open tasks whose ONLY unsatisfied dependency was `closed_id`.
local function newly_unblocked(closed_id)
  local out = {}
  for _, d in ipairs(q([[SELECT t.id, t.key FROM trk_deps d JOIN trk_tasks t ON t.id = d.task_id
                         WHERE d.depends_on = ? AND t.status NOT IN ('done','cancelled')]], { closed_id })) do
    local other = one([[SELECT count(*) AS n FROM trk_deps d JOIN trk_tasks x ON x.id = d.depends_on
                        WHERE d.task_id = ? AND d.depends_on <> ? AND x.status NOT IN ('done','cancelled')]],
      { d.id, closed_id })
    if other and other.n == 0 then out[#out + 1] = d.key end
  end
  return out
end

function M.set_status(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local s = a.status
  if not M.STATUSES[s] then return err("status must be open|in_progress|blocked|in_review|done|cancelled") end
  local warnings = {}
  if s == "done" then
    local p = project_row(t.project)
    for _, c in ipairs(q("SELECT * FROM trk_criteria WHERE task_id = ? ORDER BY id", { t.id })) do
      local why = {}
      if c.last_result ~= "pass" then why[#why + 1] = "unmet" end
      if c.test_ref == "" then why[#why + 1] = "unlinked" end
      if #why > 0 then warnings[#warnings + 1] = string.format("#%d %s (%s)", c.id, c.text, table.concat(why, ", ")) end
    end
    if #warnings > 0 and p.close_policy == "strict" and not truthy(a.override) then
      return err("`" .. t.key .. "` cannot close: project " .. p.key .. " is strict and criteria are not met:\n- "
        .. table.concat(warnings, "\n- ") .. "\n(override=true closes anyway)")
    end
  end
  local closed = M.CLOSED[s] and (t.closed_ts or now()) or nil
  run("UPDATE trk_tasks SET status = ?, closed_ts = NULLIF(?,0), updated = ? WHERE id = ?", { s, closed or 0, now(), t.id })
  local out = { "Status " .. task_line(task_by_id(t.id)):sub(3) }
  if #warnings > 0 then out[#out + 1] = "criteria warnings:\n- " .. table.concat(warnings, "\n- ") end
  if M.CLOSED[s] then
    local freed = newly_unblocked(t.id)
    if #freed > 0 then out[#out + 1] = "now unblocked: " .. table.concat(freed, ", ") end
  end
  return table.concat(out, "\n")
end

-- ---- tags ----------------------------------------------------------------------------
local G = {}
function G.add(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  if type(a.tag) ~= "string" or a.tag == "" then return err("needs `tag`") end
  run("INSERT OR IGNORE INTO trk_tags(task_id, tag) VALUES(?, ?)", { t.id, a.tag })
  return "Tagged `" .. t.key .. "` " .. a.tag
end
function G.remove(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local r = run("DELETE FROM trk_tags WHERE task_id = ? AND tag = ?", { t.id, a.tag or "" })
  return (r.changes > 0 and "Removed tag " or "No tag ") .. tostring(a.tag) .. " on `" .. t.key .. "`"
end
function G.rule_add(a)
  if type(a.tag) ~= "string" or a.tag == "" then return err("rule_add needs `tag`") end
  local mk, mr, mp = a.match_kind or "", a.match_regex or "", a.match_parent_kind or ""
  if mk == "" and mr == "" and mp == "" then return err("rule_add needs at least one of match_kind/match_regex/match_parent_kind") end
  if mr ~= "" and not pcall(gold.re.find, "", mr) then return err("match_regex does not compile") end
  local id = uid()
  run("INSERT INTO trk_tag_rules(uid,tag,match_kind,match_regex,match_parent_kind,project,created) VALUES(?,?,?,?,?,?,?)",
    { id, a.tag, mk, mr, mp, norm_key(a.project) or "", now() })
  return "Added tag rule " .. id .. " → " .. a.tag
end
function G.rule_list(a)
  local rows = (a.project and a.project ~= "")
    and q("SELECT * FROM trk_tag_rules WHERE project IN ('', ?) ORDER BY created", { norm_key(a.project) })
    or q("SELECT * FROM trk_tag_rules ORDER BY created")
  if #rows == 0 then return "No tag rules" end
  local out = { "**Tag rules (" .. #rows .. ")**" }
  for _, r in ipairs(rows) do
    local m = {}
    if r.match_kind ~= "" then m[#m + 1] = "kind=" .. r.match_kind end
    if r.match_regex ~= "" then m[#m + 1] = "regex=/" .. r.match_regex .. "/" end
    if r.match_parent_kind ~= "" then m[#m + 1] = "parent_kind=" .. r.match_parent_kind end
    out[#out + 1] = string.format("- %s → %s  [%s]%s", r.uid, r.tag, table.concat(m, " "), r.project ~= "" and (" project=" .. r.project) or "")
  end
  return table.concat(out, "\n")
end
function G.rule_remove(a)
  local r = run("DELETE FROM trk_tag_rules WHERE uid = ?", { tostring(a.rule_id or "") })
  return r.changes > 0 and ("Removed rule " .. a.rule_id) or err("no such rule '" .. tostring(a.rule_id) .. "'")
end

-- ---- commits -------------------------------------------------------------------------------
local K = {}
function K.link(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  if type(a.commit) ~= "string" or a.commit == "" then return err("commits link needs `commit`") end
  local r = run("INSERT OR IGNORE INTO trk_commits(task_id,repo,commit_hash,message,linked_at) VALUES(?,?,?,?,?)",
    { t.id, a.repo or ".", a.commit, a.message or "", now() })
  return (r.changes > 0 and "Linked " or "Already linked ") .. a.commit:sub(1, 10) .. " → `" .. t.key .. "`"
end
function K.scan(a)
  local repo = (a.repo and a.repo ~= "") and a.repo or "."
  local max = math.min(int(a.max_commits, 200), M.MAX_SCAN)
  local cmd = "git -C '" .. repo:gsub("'", "'\\''") .. "' log -n " .. max .. " --format=%H%x09%s 2>/dev/null"
  local ok, res = pcall(require("proc").run, cmd, 60)
  if not ok or type(res) ~= "table" or res.code ~= 0 then return err("git log failed in " .. repo) end
  local scanned, matched, linked, skipped = 0, 0, 0, 0
  local closing = truthy(a.close_keywords)
  local closes = {}
  for line in (res.out or ""):gmatch("[^\n]+") do
    local hash, subject = line:match("^(%x+)\t(.*)$")
    if hash then
      scanned = scanned + 1
      for key in subject:gmatch("%f[%w]([A-Z][A-Z0-9]*%-%d+)%f[^%w]") do
        local t = task_row(key)
        if t then
          matched = matched + 1
          local r = run("INSERT OR IGNORE INTO trk_commits(task_id,repo,commit_hash,message,linked_at) VALUES(?,?,?,?,?)",
            { t.id, repo, hash, subject, now() })
          if r.changes > 0 then linked = linked + 1 else skipped = skipped + 1 end
        end
      end
      -- "Fixes BOG-7", "closes BOG-7", "resolved: BOG-7" -- GitHub's closing
      -- keywords, applied to tickets. Opt-in (close_keywords=true), and a
      -- strict project's close gate still decides.
      if closing then
        local low = subject:lower()
        for kw, key in low:gmatch("(%a+)[%s:]+(%a[%w]*%-%d+)") do
          if kw:match("^fix") or kw:match("^close") or kw:match("^resolve") then
            if ({ fix = 1, fixes = 1, fixed = 1, close = 1, closes = 1, closed = 1,
                  resolve = 1, resolves = 1, resolved = 1 })[kw] then
              closes[#closes + 1] = key:upper()
            end
          end
        end
      end
    end
  end
  local out = { string.format("Scanned %d commits: %d key mentions, %d linked, %d already linked", scanned, matched, linked, skipped) }
  local seen = {}
  for _, key in ipairs(closes) do
    local t = task_row(key)
    if t and not seen[key] and not M.CLOSED[t.status] then
      seen[key] = true
      out[#out + 1] = M.set_status{ key = key, status = "done" }
    end
  end
  return table.concat(out, "\n")
end

-- ---- GitHub issues, through the gh CLI ---------------------------------------------------------
-- gh already owns auth (keyring, GH_TOKEN in CI), Enterprise hosts and token
-- scoping, so boggart shells out and keeps only the link (trk_issues). Every
-- argument is single-quoted; bodies travel in a temp file, never on the
-- command line. M.GH is the binary (BOGGART_GH overrides; tests use a fake).
M.GH = os.getenv("BOGGART_GH") or "gh"

local function sq(x) return "'" .. tostring(x):gsub("'", "'\\''") .. "'" end

function M.gh(args, timeout)
  local parts = { sq(M.GH) }
  for _, a in ipairs(args) do parts[#parts + 1] = sq(a) end
  local ok, r = pcall(require("proc").run, table.concat(parts, " ") .. " 2>&1", timeout or 60)
  if not ok then return nil, tostring(r) end
  if type(r) ~= "table" then return nil, "gh did not run" end
  local out = (r.out or ""):gsub("%s+$", "")
  if r.code ~= 0 then return nil, out ~= "" and out or ("gh exited " .. tostring(r.code)) end
  return out
end

local function default_repo()
  local out = M.gh({ "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" }, 30)
  return out and out:match("^%s*([%w%._%-]+/[%w%._%-]+)%s*$") or nil
end

local function resolve_repo(a)
  if a.repo and a.repo ~= "" then return a.repo end
  return default_repo()
end

local function issue_link(t, repo)
  if repo then return one("SELECT * FROM trk_issues WHERE task_id = ? AND repo = ?", { t.id, repo }) end
  return one("SELECT * FROM trk_issues WHERE task_id = ? ORDER BY synced_at DESC", { t.id })
end

-- The issue body: the description, the acceptance checklist (GitHub renders
-- - [x] as a checkbox) and a line saying where the ticket lives.
function M.issue_body(t)
  local out = {}
  if t.description and t.description ~= "" then out[#out + 1] = t.description; out[#out + 1] = "" end
  local crit = q("SELECT * FROM trk_criteria WHERE task_id = ? ORDER BY id", { t.id })
  if #crit > 0 then
    out[#out + 1] = "## Acceptance criteria"
    for _, c in ipairs(crit) do
      out[#out + 1] = string.format("- [%s] %s%s", c.last_result == "pass" and "x" or " ", c.text,
        c.test_ref ~= "" and (" (`" .. c.test_ref .. "`)") or "")
    end
    out[#out + 1] = ""
  end
  out[#out + 1] = "_Tracked as `" .. t.key .. "` in the boggart tracker._"
  return table.concat(out, "\n")
end

local I = {}
function I.create(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local repo = resolve_repo(a)
  if not repo then return err("no `repo` given and none detected here (gh repo view)") end
  local have = issue_link(t, repo)
  if have then return "`" .. t.key .. "` already has " .. repo .. "#" .. have.number .. " " .. have.url end
  -- labels: only ones that exist in the repo -- gh refuses an unknown label
  local tags = q("SELECT tag FROM trk_tags WHERE task_id = ? ORDER BY tag", { t.id })
  local labels = {}
  if #tags > 0 then
    local existing = {}
    local out = M.gh({ "label", "list", "--repo", repo, "--limit", "200", "--json", "name", "--jq", ".[].name" }, 30)
    for name in (out or ""):gmatch("[^\n]+") do existing[name] = true end
    for _, g in ipairs(tags) do if existing[g.tag] then labels[#labels + 1] = g.tag end end
  end
  local body_path = os.tmpname()
  local f = io.open(body_path, "w"); f:write(M.issue_body(t)); f:close()
  local args = { "issue", "create", "--repo", repo, "--title", "[" .. t.key .. "] " .. t.title, "--body-file", body_path }
  for _, l in ipairs(labels) do args[#args + 1] = "--label"; args[#args + 1] = l end
  local out, e = M.gh(args, 60)
  os.remove(body_path)
  if not out then return err("gh issue create failed: " .. tostring(e)) end
  local url = out:match("(https?://%S+/issues/%d+)")
  local number = url and tonumber(url:match("/issues/(%d+)$"))
  if not number then return err("gh did not return an issue URL: " .. out) end
  run("INSERT OR REPLACE INTO trk_issues(task_id,repo,number,url,state,remote_title,synced_at) VALUES(?,?,?,?,?,?,?)",
    { t.id, repo, number, url, "OPEN", "[" .. t.key .. "] " .. t.title, now() })
  return "Created " .. repo .. "#" .. number .. " for `" .. t.key .. "` " .. url
    .. (#labels > 0 and ("  (labels: " .. table.concat(labels, ", ") .. ")") or "")
end

function I.link(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local repo = resolve_repo(a)
  local number = int(a.number)
  if not (repo and number) then return err("issue link needs `number` (and `repo` unless it can be detected)") end
  local out, e = M.gh({ "issue", "view", tostring(number), "--repo", repo, "--json", "state,title,url" }, 30)
  if not out then return err("gh issue view failed: " .. tostring(e)) end
  local okj, v = pcall(require("json").decode, out)
  if not okj or type(v) ~= "table" then return err("unexpected gh output: " .. out) end
  run("INSERT OR REPLACE INTO trk_issues(task_id,repo,number,url,state,remote_title,synced_at) VALUES(?,?,?,?,?,?,?)",
    { t.id, repo, number, v.url or "", v.state or "", v.title or "", now() })
  return "Linked `" .. t.key .. "` to " .. repo .. "#" .. number .. " (" .. tostring(v.state) .. ")"
end

-- Refresh one link from GitHub and describe any drift. -> line, drifted?
local function sync_one(t, link)
  local out, e = M.gh({ "issue", "view", tostring(link.number), "--repo", link.repo, "--json", "state,title,url" }, 30)
  if not out then return "`" .. t.key .. "` " .. link.repo .. "#" .. link.number .. ": gh failed: " .. tostring(e), true end
  local okj, v = pcall(require("json").decode, out)
  if not okj or type(v) ~= "table" then return "`" .. t.key .. "`: unexpected gh output", true end
  run("UPDATE trk_issues SET state = ?, remote_title = ?, url = ?, synced_at = ? WHERE task_id = ? AND repo = ?",
    { v.state or "", v.title or "", v.url or link.url, now(), t.id, link.repo })
  -- `gh issue view` also answers for pull requests, whose done state is MERGED
  local closed_remote = v.state == "CLOSED" or v.state == "MERGED"
  local closed_local = M.CLOSED[t.status] == true
  local ref = link.repo .. "#" .. link.number
  if closed_remote and not closed_local then
    return string.format("`%s` DRIFT: %s is closed on GitHub but the ticket is %s", t.key, ref, t.status), true
  elseif closed_local and not closed_remote then
    return string.format("`%s` DRIFT: the ticket is %s but %s is still open (issue close)", t.key, t.status, ref), true
  end
  return string.format("`%s` in sync with %s (%s)", t.key, ref, v.state), false
end

function I.sync(a)
  local targets = {}
  if a.key and a.key ~= "" then
    local t = task_row(a.key)
    if not t then return err("no such task '" .. tostring(a.key) .. "'") end
    local l = issue_link(t, (a.repo and a.repo ~= "") and a.repo or nil)
    if not l then return err("`" .. t.key .. "` has no linked issue (issue create / issue link)") end
    targets[1] = { t = t, l = l }
  elseif a.project and a.project ~= "" then
    for _, r in ipairs(q([[SELECT i.*, t.key AS tkey FROM trk_issues i JOIN trk_tasks t ON t.id = i.task_id
                           WHERE t.project = ? ORDER BY t.seq]], { norm_key(a.project) })) do
      targets[#targets + 1] = { t = task_by_id(r.task_id), l = r }
    end
  else
    return err("issue sync needs `key` or `project`")
  end
  local out, drift = {}, 0
  for _, x in ipairs(targets) do
    local line, d = sync_one(x.t, x.l)
    out[#out + 1] = "- " .. line
    if d then drift = drift + 1 end
  end
  table.insert(out, 1, string.format("**Synced %d issue(s): %d drifted**", #targets, drift))
  return table.concat(out, "\n")
end

function I.close(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local l = issue_link(t, (a.repo and a.repo ~= "") and a.repo or nil)
  if not l then return err("`" .. t.key .. "` has no linked issue") end
  local comment = (a.message and a.message ~= "") and a.message or ("Closed from boggart: `" .. t.key .. "` is " .. t.status .. ".")
  local out, e = M.gh({ "issue", "close", tostring(l.number), "--repo", l.repo, "--comment", comment }, 60)
  if not out then return err("gh issue close failed: " .. tostring(e)) end
  run("UPDATE trk_issues SET state = 'CLOSED', synced_at = ? WHERE task_id = ? AND repo = ?", { now(), t.id, l.repo })
  return "Closed " .. l.repo .. "#" .. l.number .. " for `" .. t.key .. "`"
end

-- ---- dependencies and the resolver -----------------------------------------------------------
local D = {}
local function reaches(from_id, target_id)
  -- bounded BFS along depends_on edges: does from_id (transitively) depend on target_id?
  local seen, queue, n = { [from_id] = true }, { from_id }, 0
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    n = n + 1
    assert(n <= 10000, "dependency graph exceeds 10000 nodes")
    if cur == target_id then return true end
    for _, e in ipairs(q("SELECT depends_on FROM trk_deps WHERE task_id = ?", { cur })) do
      if not seen[e.depends_on] then seen[e.depends_on] = true; queue[#queue + 1] = e.depends_on end
    end
  end
  return false
end
function D.add(a)
  local t, d = task_row(a.key), task_row(a.depends_on)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  if not d then return err("no such task '" .. tostring(a.depends_on) .. "'") end
  if t.id == d.id then return err("a task cannot depend on itself") end
  if t.project ~= d.project then return err("dependencies must stay within one project") end
  local n = one("SELECT count(*) AS n FROM trk_deps WHERE task_id = ?", { t.id })
  if n.n >= M.MAX_DEPS then return err("at most " .. M.MAX_DEPS .. " dependencies per task") end
  if reaches(d.id, t.id) then return err("`" .. t.key .. "` → `" .. d.key .. "` would create a cycle") end
  local r = run("INSERT OR IGNORE INTO trk_deps(task_id, depends_on) VALUES(?, ?)", { t.id, d.id })
  return (r.changes > 0 and "`" or "Already: `") .. t.key .. "` depends on `" .. d.key .. "`"
end
function D.remove(a)
  local t, d = task_row(a.key), task_row(a.depends_on)
  if not (t and d) then return err("no such task") end
  local r = run("DELETE FROM trk_deps WHERE task_id = ? AND depends_on = ?", { t.id, d.id })
  return r.changes > 0 and ("Removed `" .. t.key .. "` → `" .. d.key .. "`") or err("no such dependency")
end
function D.list(a)
  local t = task_row(a.key)
  if not t then return err("no such task '" .. tostring(a.key) .. "'") end
  local waits = q([[SELECT t.* FROM trk_deps d JOIN trk_tasks t ON t.id = d.depends_on WHERE d.task_id = ? ORDER BY t.key]], { t.id })
  local blocks = q([[SELECT t.* FROM trk_deps d JOIN trk_tasks t ON t.id = d.task_id WHERE d.depends_on = ? ORDER BY t.key]], { t.id })
  local out = { "**`" .. t.key .. "` waits on (" .. #waits .. ")**" }
  for _, x in ipairs(waits) do out[#out + 1] = task_line(x) end
  out[#out + 1] = "**blocks (" .. #blocks .. ")**"
  for _, x in ipairs(blocks) do out[#out + 1] = task_line(x) end
  return table.concat(out, "\n")
end

-- The resolver (design §5.2): classify every open task as ready / blocked /
-- waiting_on_children and emit Kahn layers. Returns the plan table.
function M.resolve_plan(project, goal_key)
  local open = q([[SELECT * FROM trk_tasks WHERE project = ? AND status NOT IN ('done','cancelled')
                   ORDER BY priority, seq]], { project })
  local by_id = {}
  for _, t in ipairs(open) do by_id[t.id] = t end
  if goal_key and goal_key ~= "" then
    local g = task_row(goal_key)
    if not g then return nil, "no such goal '" .. goal_key .. "'" end
    if not by_id[g.id] then return { project = project, goal = g.key, ready = {}, blocked = {}, waiting = {}, layers = {} } end
    local keep, work, n = {}, { g.id }, 0
    while #work > 0 do
      local id = table.remove(work); n = n + 1
      assert(n <= 10000, "goal closure exceeds 10000 nodes")
      if by_id[id] and not keep[id] then
        keep[id] = true
        for _, c in ipairs(q("SELECT id FROM trk_tasks WHERE parent_id = ?", { id })) do work[#work + 1] = c.id end
        for _, e in ipairs(q("SELECT depends_on FROM trk_deps WHERE task_id = ?", { id })) do work[#work + 1] = e.depends_on end
      end
    end
    local kept = {}
    for _, t in ipairs(open) do if keep[t.id] then kept[#kept + 1] = t end end
    open, by_id = kept, {}
    for _, t in ipairs(open) do by_id[t.id] = t end
  end
  local edges, indeg, has_open_child = {}, {}, {}
  for _, t in ipairs(open) do
    edges[t.id] = {}; indeg[t.id] = 0
    if t.parent_id and by_id[t.parent_id] then has_open_child[t.parent_id] = true end
  end
  for _, t in ipairs(open) do
    for _, e in ipairs(q("SELECT depends_on FROM trk_deps WHERE task_id = ?", { t.id })) do
      if by_id[e.depends_on] then
        edges[t.id][#edges[t.id] + 1] = e.depends_on
        indeg[t.id] = indeg[t.id] + 1
      end
    end
  end
  local plan = { project = project, goal = goal_key, ready = {}, blocked = {}, waiting = {}, layers = {} }
  for _, t in ipairs(open) do
    local item = { key = t.key, uid = t.uid, title = t.title, kind = t.kind, priority = t.priority, recipe_ref = t.recipe }
    if #edges[t.id] > 0 then
      local b = {}; for _, id in ipairs(edges[t.id]) do b[#b + 1] = by_id[id].key end
      item.blockers = b; plan.blocked[#plan.blocked + 1] = item
    elseif has_open_child[t.id] then plan.waiting[#plan.waiting + 1] = item
    else plan.ready[#plan.ready + 1] = item end
  end
  assert(#plan.ready + #plan.blocked + #plan.waiting == #open, "resolver lost a task")
  -- Kahn layers over unsatisfied edges (dependency first).
  local remaining, rounds = #open, 0
  local rev = {}
  for id, deps in pairs(edges) do for _, d in ipairs(deps) do rev[d] = rev[d] or {}; rev[d][#rev[d] + 1] = id end end
  local deg = {}; for id, v in pairs(indeg) do deg[id] = v end
  while remaining > 0 do
    rounds = rounds + 1
    assert(rounds <= 1000, "more than 1000 layers")
    local layer = {}
    for id, v in pairs(deg) do if v == 0 then layer[#layer + 1] = id end end
    assert(#layer > 0, "dependency cycle among open tasks")
    table.sort(layer, function(x, y) return by_id[x].key < by_id[y].key end)
    local keys = {}
    for _, id in ipairs(layer) do
      keys[#keys + 1] = by_id[id].key
      deg[id] = nil; remaining = remaining - 1
      for _, dep in ipairs(rev[id] or {}) do if deg[dep] then deg[dep] = deg[dep] - 1 end end
    end
    plan.layers[#plan.layers + 1] = keys
  end
  return plan
end

function D.resolve(a)
  local project = norm_key(a.project)
  local goal = a.goal
  if (not project or project == "") and goal and goal ~= "" then
    local g = task_row(goal); if g then project = g.project end
  end
  if not project_row(project) then return err("deps resolve needs a `project` (or a `goal` task)") end
  local ok, plan, e = pcall(M.resolve_plan, project, goal)
  if not ok then return err(tostring(plan)) end
  if not plan then return err(e) end
  if a.format == "json" then return require("json").encode(plan) end
  local out = { "**Plan for " .. project .. (goal and goal ~= "" and (" → " .. goal) or "") .. "**" }
  out[#out + 1] = "\nReady now (" .. #plan.ready .. ")"
  for _, x in ipairs(plan.ready) do out[#out + 1] = string.format("- `%s` [%s] P%d %s", x.key, x.kind, x.priority, x.title) end
  if #plan.blocked > 0 then
    out[#out + 1] = "\nBlocked (" .. #plan.blocked .. ")"
    for _, x in ipairs(plan.blocked) do out[#out + 1] = string.format("- `%s` %s — waits on %s", x.key, x.title, table.concat(x.blockers, ", ")) end
  end
  if #plan.waiting > 0 then
    out[#out + 1] = "\nWaiting on subtasks (" .. #plan.waiting .. ")"
    for _, x in ipairs(plan.waiting) do out[#out + 1] = string.format("- `%s` %s", x.key, x.title) end
  end
  if #plan.layers > 0 then
    out[#out + 1] = "\nOrder"
    for i, l in ipairs(plan.layers) do out[#out + 1] = string.format("%d. %s", i, table.concat(l, ", ")) end
  end
  return table.concat(out, "\n")
end

-- ---- queries ------------------------------------------------------------------------------------
M.TASK_COLUMNS = { "key", "project", "kind", "status", "priority", "depth", "title", "parent", "recipe", "created", "updated" }

function M.query_tasks(a)
  local where, vals = { "1=1" }, {}
  local function add(cond, v) where[#where + 1] = cond; vals[#vals + 1] = v end
  if a.project and a.project ~= "" then add("t.project = ?", norm_key(a.project)) end
  if a.status and a.status ~= "" then add("t.status = ?", a.status) end
  if a.kind and a.kind ~= "" then add("t.kind = ?", a.kind) end
  if a.tag and a.tag ~= "" then add("EXISTS (SELECT 1 FROM trk_tags g WHERE g.task_id = t.id AND g.tag = ?)", a.tag) end
  if a.parent and a.parent ~= "" then
    local p = task_row(a.parent); add("t.parent_id = ?", p and p.id or -1)
  end
  if a.title_pattern and a.title_pattern ~= "" then add("t.title LIKE ?", "%" .. a.title_pattern .. "%") end
  local limit = math.max(1, math.min(int(a.limit, M.DEFAULT_LIMIT), M.MAX_LIMIT))
  local offset = math.max(0, int(a.offset, 0))
  vals[#vals + 1] = limit; vals[#vals + 1] = offset
  return q("SELECT t.*, (SELECT key FROM trk_tasks x WHERE x.id = t.parent_id) AS parent FROM trk_tasks t WHERE "
    .. table.concat(where, " AND ") .. " ORDER BY t.project, t.seq LIMIT ? OFFSET ?", vals), limit
end

local function render_tree(project, parent_id, depth, out, budget)
  local rows = parent_id and q("SELECT * FROM trk_tasks WHERE parent_id = ? ORDER BY sort_order", { parent_id })
    or q("SELECT * FROM trk_tasks WHERE project = ? AND parent_id IS NULL ORDER BY sort_order", { project })
  for _, t in ipairs(rows) do
    if budget.n <= 0 then return end
    budget.n = budget.n - 1
    out[#out + 1] = string.rep("  ", depth) .. task_line(t)
    render_tree(project, t.id, depth + 1, out, budget)
  end
end

function M.query(a)
  local view = (a.view and a.view ~= "") and a.view or "tasks"
  local project = norm_key(a.project)
  if view == "tasks" then
    local rows, limit = M.query_tasks(a)
    local out = { "**Tasks (" .. #rows .. (#rows == limit and "+" or "") .. ")**" }
    for _, t in ipairs(rows) do out[#out + 1] = task_line(t) end
    return table.concat(out, "\n")
  elseif view == "tree" then
    if not project_row(project) then return err("view=tree needs `project`") end
    local out, root = { "**" .. project .. " tree**" }, nil
    if a.parent and a.parent ~= "" then
      root = task_row(a.parent); if not root then return err("no such parent") end
      out[#out + 1] = task_line(root)
    end
    render_tree(project, root and root.id, root and 1 or 0, out, { n = M.MAX_LIMIT })
    return table.concat(out, "\n")
  elseif view == "rollup" then
    local rows = (project and project ~= "")
      and q("SELECT project, kind, status, count(*) AS n FROM trk_tasks WHERE project = ? GROUP BY 1,2,3 ORDER BY 1,2,3", { project })
      or q("SELECT project, kind, status, count(*) AS n FROM trk_tasks GROUP BY 1,2,3 ORDER BY 1,2,3")
    local out = { "**Rollup**" }
    for _, r in ipairs(rows) do out[#out + 1] = string.format("- %s %s %s=%d", r.project, r.kind, r.status, r.n) end
    local c = one([[SELECT count(*) AS total, sum(c.last_result = 'pass') AS pass FROM trk_criteria c
                    JOIN trk_tasks t ON t.id = c.task_id WHERE ? = '' OR t.project = ?]], { project or "", project or "" })
    out[#out + 1] = string.format("criteria: %d/%d passing", tonumber(c.pass) or 0, c.total)
    return table.concat(out, "\n")
  elseif view == "criteria" then
    local rows = q([[SELECT c.*, t.key FROM trk_criteria c JOIN trk_tasks t ON t.id = c.task_id
                     WHERE ? = '' OR t.project = ? ORDER BY t.project, t.seq, c.id LIMIT ?]], { project or "", project or "", M.MAX_LIMIT })
    local out = { "**Criteria (" .. #rows .. ")**" }
    for _, c in ipairs(rows) do out[#out + 1] = "`" .. c.key .. "` " .. M.criterion_line(c):sub(3) end
    return table.concat(out, "\n")
  elseif view == "commits" then
    local rows = q([[SELECT c.*, t.key FROM trk_commits c JOIN trk_tasks t ON t.id = c.task_id
                     WHERE ? = '' OR t.project = ? ORDER BY c.linked_at DESC LIMIT ?]], { project or "", project or "", M.MAX_LIMIT })
    local out = { "**Commits (" .. #rows .. ")**" }
    for _, c in ipairs(rows) do out[#out + 1] = string.format("- `%s` %s %s", c.key, c.commit_hash:sub(1, 10), c.message or "") end
    return table.concat(out, "\n")
  elseif view == "tags" then
    local rows = q([[SELECT g.tag, count(*) AS n FROM trk_tags g JOIN trk_tasks t ON t.id = g.task_id
                     WHERE ? = '' OR t.project = ? GROUP BY g.tag ORDER BY n DESC, g.tag]], { project or "", project or "" })
    local out = { "**Tags (" .. #rows .. ")**" }
    for _, r in ipairs(rows) do out[#out + 1] = string.format("- %s ×%d", r.tag, r.n) end
    return table.concat(out, "\n")
  elseif view == "deps" then
    local rows = q([[SELECT a.key AS k, b.key AS d FROM trk_deps x JOIN trk_tasks a ON a.id = x.task_id
                     JOIN trk_tasks b ON b.id = x.depends_on WHERE ? = '' OR a.project = ? ORDER BY a.key]], { project or "", project or "" })
    local out = { "**Dependencies (" .. #rows .. ")**" }
    for _, r in ipairs(rows) do out[#out + 1] = "- `" .. r.k .. "` → `" .. r.d .. "`" end
    return table.concat(out, "\n")
  elseif view == "issues" then
    local rows = q([[SELECT i.*, t.key, t.status FROM trk_issues i JOIN trk_tasks t ON t.id = i.task_id
                     WHERE ? = '' OR t.project = ? ORDER BY t.project, t.seq LIMIT ?]], { project or "", project or "", M.MAX_LIMIT })
    local out = { "**Issues (" .. #rows .. ")**" }
    for _, r in ipairs(rows) do
      out[#out + 1] = string.format("- `%s` (%s) → %s#%d %s %s", r.key, r.status, r.repo, r.number, r.state, r.url)
    end
    return table.concat(out, "\n")
  end
  return err("view must be tasks|tree|rollup|criteria|commits|tags|deps|issues")
end

-- ---- dispatch --------------------------------------------------------------------------------------
local NOUNS = {
  project = { create = P.create, list = P.list, get = P.get, set_policy = P.set_policy },
  task = { create = T.create, get = T.get, update = T.update, move = T.move, breakdown = T.breakdown },
  criteria = { add = C.add, update = C.update, record = C.record, remove = C.remove, list = C.list },
  tag = { add = G.add, remove = G.remove, rule_add = G.rule_add, rule_list = G.rule_list, rule_remove = G.rule_remove },
  commits = { link = K.link, scan = K.scan },
  deps = { add = D.add, remove = D.remove, list = D.list, resolve = D.resolve },
  issue = { create = I.create, link = I.link, sync = I.sync, close = I.close },
}

local function valid_actions(noun)
  local t = {}
  for k in pairs(NOUNS[noun]) do t[#t + 1] = k end
  table.sort(t)
  return table.concat(t, "|")
end

-- The native backend: a tool call's arguments -> text. Never raises.
function M.native(a)
  a = a or {}
  local ok, e = M.ensure_schema()
  if not ok then return err(tostring(e)) end
  local noun, action = a.noun, a.action
  local fn
  if noun == "status" then fn = M.set_status
  elseif noun == "query" then fn = M.query
  elseif noun == "import" then fn = function(x) return require("tracker_import").run(x) end
  elseif NOUNS[noun] then
    fn = NOUNS[noun][action or ""]
    if not fn then return err("unknown " .. tostring(noun) .. " action '" .. tostring(action) .. "' (" .. valid_actions(noun) .. ")") end
  else
    return err("unknown noun '" .. tostring(noun) .. "' (project|task|status|criteria|tag|commits|deps|issue|query|import)")
  end
  local okc, out = pcall(fn, a)
  if not okc then return err(tostring(out)) end
  return out
end

-- ---- backends ----------------------------------------------------------------------------------------
M.BACKEND_KEY = "config.tracker.backend"
M.BACKENDS = { native = true, station = true }

function M.backend()
  local v = bog and bog.store and bog.store.kv_get and bog.store.kv_get(M.BACKEND_KEY)
  return M.BACKENDS[v] and v or "native"
end
function M.set_backend(b)
  if not M.BACKENDS[b] then return nil, "backend must be native|station" end
  bog.store.kv_set(M.BACKEND_KEY, b)
  return b
end

-- LLM Station's tracker, over ZMQ. The parameters are station's own, so they
-- pass through; the flat wire carries strings and integers only. A station
-- backend that is down is an ERROR, never a silent write to the native store:
-- the two are separate stores, and a task created in the wrong one is lost to
-- whoever looks in the right one.
function M.station(a)
  local okz, stn = pcall(require, "stationlink")
  if not (okz and stn and stn.active and stn.active()) then
    return err("tracker backend is `station` but the LLM Station link is down (/station start, or /tracker backend native)")
  end
  local p = {}
  for k, v in pairs(a) do
    if k ~= "backend" then
      if type(v) == "boolean" then p[k] = v and "true" or "false"
      elseif type(v) == "number" then p[k] = math.type(v) == "integer" and v or tostring(v)
      elseif type(v) == "string" then p[k] = v end
    end
  end
  local out, e = stn.call("tracker", p)
  if not out then return err(tostring(e)) end
  return out
end

function M.call(a)
  a = a or {}
  local b = (a.backend and M.BACKENDS[a.backend]) and a.backend or M.backend()
  if b == "station" then return M.station(a) end
  return M.native(a)
end

-- ---- the tool ------------------------------------------------------------------------------------------
M.tool = {
  description = "The project tracker: projects with PROJ-123 task keys, a task hierarchy "
    .. "(epic/story/task/subtask/spike/test), statuses (open|in_progress|blocked|in_review|done|cancelled), "
    .. "acceptance criteria with a close gate, dependencies with a ready/blocked resolver, tags, commit links. "
    .. "One tool: pick a `noun` and an `action`. Nouns and actions: project create|list|get|set_policy; "
    .. "task create|get|update|move|breakdown; status (key, status[, override]); criteria add|update|record|remove|list; "
    .. "tag add|remove|rule_add|rule_list|rule_remove; commits link|scan; deps add|remove|list|resolve; "
    .. "issue create|link|sync|close (GitHub, via the gh CLI; repo defaults to this checkout's); "
    .. "query (view=tasks|tree|rollup|criteria|commits|tags|deps). Same vocabulary as LLM Station's tracker.",
  input_schema = {
    type = "object",
    properties = {
      noun = { type = "string", description = "project|task|status|criteria|tag|commits|deps|issue|query|import" },
      action = { type = "string", description = "verb within the noun (see description)" },
      project = { type = "string", description = "project key (e.g. BOG)" },
      key = { type = "string", description = "task key (PROJ-N), or project key for the project noun" },
      title = { type = "string" }, name = { type = "string", description = "project name" },
      kind = { type = "string", description = "epic|story|task|subtask|spike|test" },
      parent = { type = "string", description = "parent task key (task create/move; query filter)" },
      description = { type = "string" },
      priority = { type = "integer", description = "1..5 (default 3)" },
      recipe = { type = "string" },
      status = { type = "string", description = "open|in_progress|blocked|in_review|done|cancelled" },
      override = { type = "boolean", description = "force a strict close past unmet criteria" },
      close_policy = { type = "string", description = "advisory|strict" },
      text = { type = "string", description = "acceptance-criterion text" },
      test_ref = { type = "string", description = "criterion test ref (tests/x::T)" },
      criterion_id = { type = "integer" }, result = { type = "string", description = "pass|fail" },
      tag = { type = "string" }, match_kind = { type = "string" }, match_regex = { type = "string" },
      match_parent_kind = { type = "string" }, rule_id = { type = "string" },
      repo = { type = "string", description = "git repo path (commits) or owner/name (issue)" },
      number = { type = "integer", description = "GitHub issue number (issue link)" },
      commit = { type = "string" }, message = { type = "string" },
      max_commits = { type = "integer" },
      close_keywords = { type = "boolean", description = "commits scan: 'Fixes KEY'/'Closes KEY' mark the ticket done" },
      depends_on = { type = "string" }, goal = { type = "string" }, format = { type = "string", description = "json for deps resolve" },
      view = { type = "string", description = "tasks|tree|rollup|criteria|commits|tags|deps|issues" },
      before = { type = "string" }, to_root = { type = "boolean" },
      subtasks = { type = "string", description = "newline/;-separated child titles (task breakdown)" },
      title_pattern = { type = "string" }, limit = { type = "integer" }, offset = { type = "integer" },
      backend = { type = "string", description = "native|station for this call only (default: /tracker backend)" },
    },
    required = { "noun" },
  },
  run = function(a) return M.call(a) end,
}

function M.register()
  if bog and bog.tools and bog.tools.register then bog.tools.register("tracker", M.tool) end
end

return M
