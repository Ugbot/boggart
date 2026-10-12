-- tracker_import.lua -- one-shot import from ai-grind's tracker (devtools-mcp)
-- into boggart's native tracker (lua/tracker_core.lua). The `tracker` tool's
-- `import` noun, mirroring LLM Station's.
--
--   tracker{ noun = "import" [, path = "~/.devtools-mcp/tracker.db"] [, project = "KEY"] }
--
-- Keys, uids and each project's next_seq are preserved, so PROJ-123 means the
-- same task in both stores and new keys continue the sequence. A project that
-- already exists natively is SKIPPED, never merged: the two stores are
-- independent after the import, and a silent merge could interleave two
-- histories under one key. Read-only on the source (ATTACHed, only SELECTed),
-- and one transaction on the target: an import lands whole or not at all.
local M = {}

M.DEFAULT_PATH = "~/.devtools-mcp/tracker.db"

local function expand(p)
  if p:sub(1, 2) == "~/" then return (sys and sys.home and sys.home() or os.getenv("HOME")) .. p:sub(2) end
  return p
end

-- "2026-08-08T13:19:26.350718+00:00" -> epoch seconds (UTC). nil on no match.
-- Pure arithmetic (Howard Hinnant's days_from_civil): os.time() interprets its
-- table as LOCAL time, and correcting that with "the current UTC offset" is
-- wrong for any date on the other side of a DST change.
local function days_from_civil(y, m, d)
  y = (m <= 2) and (y - 1) or y
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end
function M.iso_to_epoch(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, se = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  local secs = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
  -- an explicit offset ("+01:00" / "-05:30"); "Z" and none mean UTC
  local sign, oh, om = s:match("([%+%-])(%d%d):?(%d%d)$")
  if sign and s:find("T", 1, true) then
    local off = tonumber(oh) * 3600 + tonumber(om) * 60
    secs = secs - (sign == "+" and off or -off)
  end
  return secs
end

function M.run(a)
  a = a or {}
  local path = expand((a.path and a.path ~= "") and a.path or M.DEFAULT_PATH)
  if sys.stat(path) ~= "file" then return "Error: no ai-grind tracker at " .. path end
  local only = a.project and a.project ~= "" and a.project:upper() or nil
  local db = bog.db
  local tc = require("tracker_core")
  tc.ensure_schema()

  db:run("ATTACH DATABASE ? AS aig", { path })
  local ok, res = pcall(function()
    local projects = db:query("SELECT * FROM aig.projects ORDER BY key") or {}
    local imported, skipped, counts = {}, {}, { tasks = 0, criteria = 0, deps = 0, tags = 0, rules = 0, commits = 0 }
    db:run("BEGIN IMMEDIATE")
    local committed = false
    local okb, e = pcall(function()
      for _, p in ipairs(projects) do
        if not only or p.key == only then
          if tc.project_row(p.key) then
            skipped[#skipped + 1] = p.key
          else
            db:run([[INSERT INTO trk_projects(key,uid,name,description,close_policy,next_seq,created,updated)
                     VALUES(?,?,?,?,?,?,?,?)]],
              { p.key, "aig:" .. p.id, p.name, p.description or "", p.close_policy or "advisory",
                p.next_seq or 1, M.iso_to_epoch(p.created_at) or os.time(), os.time() })
            -- tasks: old id -> new id, parents resolved after every row exists
            local idmap = {}
            local rows = db:query([[SELECT * FROM aig.tasks WHERE project_id = ? ORDER BY depth, id]], { p.id }) or {}
            for _, t in ipairs(rows) do
              local seq = tonumber(t.key:match("%-(%d+)$")) or 0
              local status = tc.STATUSES[t.status] and t.status or "open"
              local r = db:run([[INSERT INTO trk_tasks(uid,key,project,seq,parent_id,depth,kind,status,priority,
                    sort_order,title,description,recipe,created,updated,closed_ts)
                    VALUES(?,?,?,?,NULLIF(?,0),?,?,?,?,?,?,?,'',?,?,NULLIF(?,0))]],
                { t.uid or ("aig:" .. t.id), t.key, p.key, seq, (t.parent_id and idmap[t.parent_id]) or 0, t.depth or 0,
                  tc.KINDS[t.kind] and t.kind or "task", status, t.priority or 3, t.sort_order or 0,
                  t.title, t.description or "", M.iso_to_epoch(t.created_at) or os.time(),
                  M.iso_to_epoch(t.updated_at) or os.time(), M.iso_to_epoch(t.closed_at) or 0 })
              idmap[t.id] = r.rowid
              counts.tasks = counts.tasks + 1
            end
            for old, new in pairs(idmap) do
              for _, c in ipairs(db:query("SELECT * FROM aig.acceptance_criteria WHERE task_id = ?", { old }) or {}) do
                db:run([[INSERT INTO trk_criteria(uid,task_id,text,test_ref,last_result,last_run_at,created)
                         VALUES(?,?,?,?,?,NULLIF(?,0),?)]],
                  { c.uid or ("aig:" .. c.id), new, c.text, c.test_ref or "", c.last_result or "",
                    M.iso_to_epoch(c.last_run_at) or 0, M.iso_to_epoch(c.created_at) or os.time() })
                counts.criteria = counts.criteria + 1
              end
              for _, d in ipairs(db:query("SELECT depends_on_id FROM aig.task_deps WHERE task_id = ?", { old }) or {}) do
                if idmap[d.depends_on_id] then
                  db:run("INSERT OR IGNORE INTO trk_deps(task_id, depends_on) VALUES(?, ?)", { new, idmap[d.depends_on_id] })
                  counts.deps = counts.deps + 1
                end
              end
              for _, g in ipairs(db:query([[SELECT g.name FROM aig.task_tags x JOIN aig.tags g ON g.id = x.tag_id
                                            WHERE x.task_id = ?]], { old }) or {}) do
                db:run("INSERT OR IGNORE INTO trk_tags(task_id, tag) VALUES(?, ?)", { new, g.name })
                counts.tags = counts.tags + 1
              end
              for _, c in ipairs(db:query("SELECT * FROM aig.task_commits WHERE task_id = ?", { old }) or {}) do
                db:run([[INSERT OR IGNORE INTO trk_commits(task_id,repo,commit_hash,message,linked_at)
                         VALUES(?,?,?,?,?)]],
                  { new, c.repo_path or ".", c.commit_hash, c.message_snippet or "", M.iso_to_epoch(c.linked_at) or os.time() })
                counts.commits = counts.commits + 1
              end
            end
            for _, r in ipairs(db:query([[SELECT r.*, g.name AS tag FROM aig.tag_rules r JOIN aig.tags g ON g.id = r.tag_id
                                          WHERE r.project_id = ? AND r.enabled = 1]], { p.id }) or {}) do
              db:run([[INSERT OR IGNORE INTO trk_tag_rules(uid,tag,match_kind,match_regex,match_parent_kind,project,created)
                       VALUES(?,?,?,?,?,?,?)]],
                { "aig:" .. r.id, r.tag, r.match_kind or "", r.match_regex or "", r.match_parent_kind or "", p.key, os.time() })
              counts.rules = counts.rules + 1
            end
            imported[#imported + 1] = p.key
          end
        end
      end
    end)
    if okb then db:run("COMMIT"); committed = true else db:run("ROLLBACK") end
    if not committed then error(e, 0) end
    return { imported = imported, skipped = skipped, counts = counts }
  end)
  pcall(db.run, db, "DETACH DATABASE aig")
  if not ok then return "Error: import failed, nothing was written: " .. tostring(res) end
  local c = res.counts
  local out = { string.format("Imported %d project(s) from %s: %d tasks, %d criteria, %d deps, %d tags, %d tag rules, %d commit links",
    #res.imported, path, c.tasks, c.criteria, c.deps, c.tags, c.rules, c.commits) }
  if #res.imported > 0 then out[#out + 1] = "imported: " .. table.concat(res.imported, ", ") end
  if #res.skipped > 0 then out[#out + 1] = "skipped (already in the native tracker): " .. table.concat(res.skipped, ", ") end
  if only and #res.imported == 0 and #res.skipped == 0 then out[#out + 1] = "no ai-grind project '" .. only .. "'" end
  return table.concat(out, "\n")
end

return M
