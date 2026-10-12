-- tracker_file.lua -- the tracker as a committed text file, and test results
-- in, for CI.
--
-- On a CI runner there is no ~/.boggart/boggart.db. The tracker's state for a
-- repository lives IN the repository instead, as .boggart/tracker.jsonl: one
-- JSON object per line, keys sorted, records in a fixed order, references by
-- key and uid (never database ids), and no volatile fields (last-run and
-- last-synced times), so re-running the same job produces no diff and a real
-- change reads as a one-line diff in review. A CI job imports the file into a
-- fresh store, does its work (scan commits, record test results, sync issues),
-- exports it again, and commits or opens a PR when it changed.
--
--   export(path[, projects])  -> summary | nil, err
--   import(path)              -> summary | nil, err   (the file REPLACES the
--                                projects it contains; others are untouched)
--   record_junit(path[, projects]) -> summary | nil, err   (criteria results from
--                                JUnit XML, e.g. `ctest --output-junit`)
local tc = require("tracker_core")
local M = {}

M.FORMAT = 1

local function q(sql, p) return bog.db:query(sql, p or {}) or {} end
local function run(sql, p) return bog.db:run(sql, p or {}) end

-- ---- canonical JSON (sorted keys, no whitespace, stable numbers) ---------------
local function enc_str(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return m[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end
function M.canonical(v)
  local t = type(v)
  if t == "string" then return enc_str(v)
  elseif t == "number" then
    if math.type(v) == "integer" or v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
    return string.format("%.17g", v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "nil" then return "null"
  elseif t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = enc_str(tostring(k)) .. ":" .. M.canonical(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("cannot encode " .. t)
end

-- ---- export ------------------------------------------------------------------------
function M.records(projects)
  tc.ensure_schema()
  local want
  if projects and #projects > 0 then
    want = {}
    for _, p in ipairs(projects) do want[p:upper()] = true end
  end
  local out = { { t = "meta", format = M.FORMAT } }
  local plist = {}
  for _, p in ipairs(q("SELECT * FROM trk_projects ORDER BY key")) do
    if not want or want[p.key] then
      plist[#plist + 1] = p.key
      out[#out + 1] = { t = "project", key = p.key, uid = p.uid, name = p.name, description = p.description,
                        close_policy = p.close_policy, next_seq = p.next_seq }
    end
  end
  for _, pk in ipairs(plist) do
    for _, r in ipairs(q("SELECT * FROM trk_tag_rules WHERE project = ? ORDER BY uid", { pk })) do
      out[#out + 1] = { t = "rule", uid = r.uid, tag = r.tag, match_kind = r.match_kind, match_regex = r.match_regex,
                        match_parent_kind = r.match_parent_kind, project = r.project }
    end
    local tasks = q([[SELECT t.*, (SELECT key FROM trk_tasks x WHERE x.id = t.parent_id) AS parent_key
                      FROM trk_tasks t WHERE t.project = ? ORDER BY t.seq]], { pk })
    for _, t in ipairs(tasks) do
      out[#out + 1] = { t = "task", key = t.key, uid = t.uid, project = t.project, parent = t.parent_key,
                        kind = t.kind, status = t.status, priority = t.priority, sort_order = t.sort_order,
                        title = t.title, description = t.description, recipe = t.recipe,
                        created = t.created, updated = t.updated, closed = t.closed_ts }
    end
    for _, t in ipairs(tasks) do
      for _, c in ipairs(q("SELECT * FROM trk_criteria WHERE task_id = ? ORDER BY id", { t.id })) do
        out[#out + 1] = { t = "criterion", task = t.key, uid = c.uid, text = c.text, test_ref = c.test_ref,
                          result = c.last_result }
      end
      for _, d in ipairs(q([[SELECT x.key FROM trk_deps d JOIN trk_tasks x ON x.id = d.depends_on
                             WHERE d.task_id = ? ORDER BY x.seq]], { t.id })) do
        out[#out + 1] = { t = "dep", task = t.key, depends_on = d.key }
      end
      for _, g in ipairs(q("SELECT tag FROM trk_tags WHERE task_id = ? ORDER BY tag", { t.id })) do
        out[#out + 1] = { t = "tag", task = t.key, tag = g.tag }
      end
      for _, c in ipairs(q("SELECT * FROM trk_commits WHERE task_id = ? ORDER BY commit_hash", { t.id })) do
        out[#out + 1] = { t = "commit", task = t.key, hash = c.commit_hash, repo = c.repo, message = c.message }
      end
      for _, i in ipairs(q("SELECT * FROM trk_issues WHERE task_id = ? ORDER BY repo", { t.id })) do
        out[#out + 1] = { t = "issue", task = t.key, repo = i.repo, number = i.number, url = i.url, state = i.state }
      end
    end
  end
  return out, plist
end

function M.export(path, projects)
  local recs, plist = M.records(projects)
  local lines = {}
  for _, r in ipairs(recs) do lines[#lines + 1] = M.canonical(r) end
  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" and sys.stat(dir) ~= "dir" then sys.mkdir_p(dir) end
  local tmp = path .. ".tmp"
  local f, e = io.open(tmp, "w")
  if not f then return nil, "cannot write " .. path .. ": " .. tostring(e) end
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  local ok, re = os.rename(tmp, path)   -- atomic: a reader never sees half a file
  if not ok then return nil, tostring(re) end
  return string.format("Exported %d project(s), %d records to %s", #plist, #recs - 1, path)
end

-- ---- import --------------------------------------------------------------------------
local function delete_project(key)
  local ids = {}
  for _, t in ipairs(q("SELECT id FROM trk_tasks WHERE project = ?", { key })) do ids[#ids + 1] = t.id end
  for _, id in ipairs(ids) do
    for _, tbl in ipairs{ "trk_criteria", "trk_tags", "trk_commits", "trk_issues" } do
      run("DELETE FROM " .. tbl .. " WHERE task_id = ?", { id })
    end
    run("DELETE FROM trk_deps WHERE task_id = ? OR depends_on = ?", { id, id })
  end
  run("DELETE FROM trk_tasks WHERE project = ?", { key })
  run("DELETE FROM trk_tag_rules WHERE project = ?", { key })
  run("DELETE FROM trk_projects WHERE key = ?", { key })
end

function M.import(path)
  tc.ensure_schema()
  local f = io.open(path)
  if not f then return nil, "no tracker file at " .. path end
  local json = require("json")
  local recs, n = {}, 0
  for line in f:lines() do
    n = n + 1
    if line:match("%S") then
      local ok, r = pcall(json.decode, line)
      if not ok or type(r) ~= "table" or type(r.t) ~= "string" then
        f:close()
        return nil, string.format("%s:%d: not a tracker record", path, n)
      end
      recs[#recs + 1] = r
    end
  end
  f:close()
  local meta = recs[1]
  if not meta or meta.t ~= "meta" then return nil, path .. ": missing the meta line (not a tracker export?)" end
  if (tonumber(meta.format) or 0) > M.FORMAT then
    return nil, path .. ": format " .. tostring(meta.format) .. " is newer than this boggart understands (" .. M.FORMAT .. ")"
  end
  local null = json.null
  local function v(x) if x == null then return nil end return x end

  bog.db:run("BEGIN IMMEDIATE")
  local ok, res = pcall(function()
    local projects, ids, counts = {}, {}, { tasks = 0, criteria = 0, deps = 0 }
    for _, r in ipairs(recs) do
      if r.t == "project" then
        delete_project(r.key)
        run([[INSERT INTO trk_projects(key,uid,name,description,close_policy,next_seq,created,updated)
              VALUES(?,?,?,?,?,?,?,?)]],
          { r.key, v(r.uid) or r.key, r.name, v(r.description) or "", r.close_policy or "advisory", r.next_seq or 1, os.time(), os.time() })
        projects[#projects + 1] = r.key
      end
    end
    -- tasks: parents are exported before children (seq order within a project
    -- is creation order, and a parent always exists before its children), but
    -- resolve parents in a second pass so the file does not have to promise that
    for _, r in ipairs(recs) do
      if r.t == "task" then
        local seq = tonumber(r.key:match("%-(%d+)$")) or 0
        local w = run([[INSERT INTO trk_tasks(uid,key,project,seq,parent_id,depth,kind,status,priority,sort_order,
              title,description,recipe,created,updated,closed_ts) VALUES(?,?,?,?,NULL,0,?,?,?,?,?,?,?,?,?,NULLIF(?,0))]],
          { v(r.uid) or r.key, r.key, r.project, seq, r.kind or "task", r.status or "open", r.priority or 3,
            v(r.sort_order) or seq, r.title, v(r.description) or "", v(r.recipe) or "", v(r.created) or os.time(),
            v(r.updated) or os.time(), v(r.closed) or 0 })
        ids[r.key] = w.rowid
        counts.tasks = counts.tasks + 1
      end
    end
    for _, r in ipairs(recs) do
      if r.t == "task" and v(r.parent) and ids[r.parent] then
        run("UPDATE trk_tasks SET parent_id = ? WHERE id = ?", { ids[r.parent], ids[r.key] })
      end
    end
    -- depths from the resolved parents
    local function depth_of(key, guard)
      guard = guard or 0
      assert(guard < 64, "parent cycle in the tracker file at " .. key)
      local row = q("SELECT parent_id FROM trk_tasks WHERE id = ?", { ids[key] })[1]
      if not row or not row.parent_id then return 0 end
      local pk = q("SELECT key FROM trk_tasks WHERE id = ?", { row.parent_id })[1].key
      return 1 + depth_of(pk, guard + 1)
    end
    for key, id in pairs(ids) do run("UPDATE trk_tasks SET depth = ? WHERE id = ?", { depth_of(key), id }) end
    for _, r in ipairs(recs) do
      local tid = r.task and ids[r.task]
      if r.t == "criterion" and tid then
        run("INSERT INTO trk_criteria(uid,task_id,text,test_ref,last_result,created) VALUES(?,?,?,?,?,?)",
          { v(r.uid) or "", tid, r.text, v(r.test_ref) or "", v(r.result) or "", os.time() })
        counts.criteria = counts.criteria + 1
      elseif r.t == "dep" and tid and ids[r.depends_on] then
        run("INSERT OR IGNORE INTO trk_deps(task_id, depends_on) VALUES(?, ?)", { tid, ids[r.depends_on] })
        counts.deps = counts.deps + 1
      elseif r.t == "tag" and tid then
        run("INSERT OR IGNORE INTO trk_tags(task_id, tag) VALUES(?, ?)", { tid, r.tag })
      elseif r.t == "commit" and tid then
        run("INSERT OR IGNORE INTO trk_commits(task_id,repo,commit_hash,message,linked_at) VALUES(?,?,?,?,?)",
          { tid, v(r.repo) or ".", r.hash, v(r.message) or "", os.time() })
      elseif r.t == "issue" and tid then
        run("INSERT OR REPLACE INTO trk_issues(task_id,repo,number,url,state,synced_at) VALUES(?,?,?,?,?,?)",
          { tid, r.repo, r.number, v(r.url) or "", v(r.state) or "", os.time() })
      elseif r.t == "rule" then
        run([[INSERT OR REPLACE INTO trk_tag_rules(uid,tag,match_kind,match_regex,match_parent_kind,project,created)
              VALUES(?,?,?,?,?,?,?)]],
          { r.uid, r.tag, v(r.match_kind) or "", v(r.match_regex) or "", v(r.match_parent_kind) or "", v(r.project) or "", os.time() })
      end
    end
    return { projects = projects, counts = counts }
  end)
  if ok then bog.db:run("COMMIT") else bog.db:run("ROLLBACK"); return nil, "import failed, nothing changed: " .. tostring(res) end
  return string.format("Imported %d project(s) from %s: %d tasks, %d criteria, %d deps",
    #res.projects, path, res.counts.tasks, res.counts.criteria, res.counts.deps)
end

-- ---- JUnit results -> acceptance criteria ---------------------------------------------------
local function unxml(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end
local function attr(tag, name)
  local v = tag:match("%s" .. name .. '="([^"]*)"') or tag:match("%s" .. name .. "='([^']*)'")
  return v and unxml(v) or nil
end

-- testcases -> { {classname, name, file, result = "pass"|"fail"|nil(skipped)} }
function M.parse_junit(xml)
  local cases = {}
  local pos = 1
  while true do
    local s, e, tag, selfclose = xml:find("<testcase(%s[^>]-)(/?)>", pos)
    if not s then break end
    local body = ""
    if selfclose ~= "/" then
      local ce = xml:find("</testcase>", e + 1, true)
      body = xml:sub(e + 1, (ce or #xml + 1) - 1)
      pos = (ce or e) + 1
    else
      pos = e + 1
    end
    local result = "pass"
    if body:find("<failure", 1, true) or body:find("<error", 1, true) then result = "fail"
    elseif body:find("<skipped", 1, true) then result = nil end
    -- ctest writes status="fail"/"notrun" on the testcase itself
    local status = attr(" " .. tag, "status")
    if status == "fail" or status == "failed" then result = "fail"
    elseif status == "notrun" or status == "disabled" then result = nil end
    cases[#cases + 1] = { classname = attr(" " .. tag, "classname") or "", name = attr(" " .. tag, "name") or "",
                          file = attr(" " .. tag, "file") or "", result = result }
  end
  return cases
end

-- Does criterion test_ref `ref` name testcase `c`? Accepted spellings:
--   name   |   classname::name   |   path::name  (path's file, or its stem, is
--   the classname or the testcase's file)
function M.ref_matches(ref, c)
  if ref == "" then return false end
  if ref == c.name then return true end
  local prefix, name = ref:match("^(.*)::([^:]+)$")
  if not prefix or name ~= c.name then return false end
  if prefix == c.classname or prefix == c.file then return true end
  local stem = prefix:match("([^/\\]+)$") or prefix
  stem = stem:gsub("%.[%w]+$", "")
  local cstem = (c.classname:match("([^%.]+)$") or c.classname)
  return stem == c.classname or stem == cstem or (c.file ~= "" and c.file:sub(-#prefix) == prefix)
end

function M.record_junit(path, projects)
  tc.ensure_schema()
  local f = io.open(path)
  if not f then return nil, "no JUnit file at " .. path end
  local xml = f:read("a"); f:close()
  local cases = M.parse_junit(xml)
  if #cases == 0 then return nil, path .. ": no <testcase> elements" end
  local pass, fail, unmatched = 0, 0, {}
  local want
  if projects and #projects > 0 then
    want = {}
    for _, p in ipairs(projects) do want[p:upper()] = true end
  end
  local crit = q([[SELECT c.id, c.test_ref, t.project FROM trk_criteria c JOIN trk_tasks t ON t.id = c.task_id
                   WHERE c.test_ref <> '']])
  for _, c in ipairs(crit) do if want and not want[c.project] then goto continue end
    local result
    for _, tcase in ipairs(cases) do
      if tcase.result and M.ref_matches(c.test_ref, tcase) then
        -- any failing case for this ref fails the criterion
        if tcase.result == "fail" then result = "fail" elseif not result then result = "pass" end
      end
    end
    if result then
      run("UPDATE trk_criteria SET last_result = ?, last_run_at = ? WHERE id = ?", { result, os.time(), c.id })
      if result == "pass" then pass = pass + 1 else fail = fail + 1 end
    else
      unmatched[#unmatched + 1] = c.test_ref
    end
    ::continue::
  end
  local out = string.format("Recorded %d criteria from %d testcases: %d pass, %d fail", pass + fail, #cases, pass, fail)
  if #unmatched > 0 then
    out = out .. string.format("; %d linked criteria had no matching testcase", #unmatched)
  end
  return out
end

return M
