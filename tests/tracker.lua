-- tracker.lua -- boggart's built-in tracker (lua/tracker_core.lua): the
-- station-compatible `tracker` tool contract, its semantics (key allocation,
-- hierarchy, close gate, resolver), backend routing, and the ai-grind import.
-- ctest reuses one HOME per suite across runs, so start from an empty tracker
-- in this suite's own (disposable) store rather than whatever a previous run
-- left behind. Before any tracker_core call, so its schema is recreated fresh.
for _, t in ipairs{ "trk_projects", "trk_tasks", "trk_criteria", "trk_deps", "trk_tags", "trk_tag_rules", "trk_commits", "trk_issues" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
bog.store.kv_del("config.tracker.backend")
local tc = require("tracker_core")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function has(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) ~= nil, n .. " -- got: " .. tostring(s)) end
local function iserr(s, n) ok(type(s) == "string" and s:find("^Error:") ~= nil, n .. " -- got: " .. tostring(s)) end
local function T(a) return tc.native(a) end

-- ---- projects + key allocation ----------------------------------------------------
has(T{ noun = "project", action = "create", key = "bog", name = "Boggart" }, "Created project `BOG` (advisory)", "project create uppercases the key")
iserr(T{ noun = "project", action = "create", key = "BOG", name = "again" }, "duplicate project refused")
iserr(T{ noun = "project", action = "create", key = "9x" }, "bad project key refused")
has(T{ noun = "project", action = "create", key = "STR", name = "Strict", close_policy = "strict" }, "(strict)", "strict project")
has(T{ noun = "task", action = "create", project = "BOG", title = "Epic one", kind = "epic" }, "`BOG-1` [epic/open] P3 Epic one", "first key is BOG-1")
has(T{ noun = "task", action = "create", project = "BOG", title = "Second", priority = 1 }, "`BOG-2` [task/open] P1", "keys increment; priority kept")
iserr(T{ noun = "task", action = "create", project = "NOPE", title = "x" }, "unknown project refused")
iserr(T{ noun = "task", action = "create", project = "BOG" }, "task without a title refused")
iserr(T{ noun = "task", action = "create", project = "BOG", title = "x", priority = 9 }, "priority out of range refused")
has(T{ noun = "project", action = "list" }, "next=`BOG-3`", "project list shows the next key")

-- ---- hierarchy ---------------------------------------------------------------------
has(T{ noun = "task", action = "breakdown", key = "BOG-1", subtasks = "Story A; Story B\nStory C" }, "into 3", "breakdown splits on ; and newline")
local s = T{ noun = "task", action = "get", key = "BOG-3" }
has(s, "kind=story", "a breakdown child of an epic is a story")
has(s, "parent: `BOG-1`", "and knows its parent")
-- the 6-level cap: BOG-3 is depth 1; four breakdowns reach depth 5 (the 6th
-- level, still legal), and one more would be a 7th
local k = "BOG-3"
for i = 1, 4 do
  local out = T{ noun = "task", action = "breakdown", key = k, subtasks = "level" .. i }
  k = out:match("`(BOG%-%d+)`", out:find("\n"))
end
iserr(T{ noun = "task", action = "breakdown", key = k, subtasks = "too deep" }, "a 7th level is refused")
has(T{ noun = "task", action = "move", key = "BOG-5", to_root = true }, "(depth 0)", "move to root")
iserr(T{ noun = "task", action = "move", key = "BOG-1", parent = "BOG-3" }, "cannot move under own descendant")
has(T{ noun = "task", action = "update", key = "BOG-2", title = "Second, renamed", priority = 2 }, "P2 Second, renamed", "update")

-- ---- criteria + close gate -------------------------------------------------------------
has(T{ noun = "task", action = "create", project = "STR", title = "Gated" }, "`STR-1`", "task in strict project")
has(T{ noun = "criteria", action = "add", key = "STR-1", text = "it works", test_ref = "tests/x::works" }, "Added criterion #", "criterion added")
local cid = tonumber(T{ noun = "criteria", action = "list", key = "STR-1" }:match("#(%d+)"))
iserr(T{ noun = "status", key = "STR-1", status = "done" }, "strict project refuses a close with unmet criteria")
has(T{ noun = "status", key = "STR-1", status = "done", override = true }, "criteria warnings", "override closes and warns")
has(T{ noun = "status", key = "STR-1", status = "open" }, "[task/open]", "reopen")
has(T{ noun = "criteria", action = "record", criterion_id = cid, result = "pass" }, "Recorded pass", "record a pass")
local done = T{ noun = "status", key = "STR-1", status = "done" }
ok(done:find("^Status") and not done:find("warnings"), "a met, linked criterion closes cleanly -- got: " .. done)
has(T{ noun = "criteria", action = "list", key = "STR-1" }, "[x]", "passing criterion marked [x]")
has(T{ noun = "status", key = "BOG-2", status = "in_review" }, "[task/in_review]", "in_review is a status")
iserr(T{ noun = "status", key = "BOG-2", status = "shipped" }, "unknown status refused")

-- ---- dependencies + resolver -------------------------------------------------------------
T{ noun = "project", action = "create", key = "DEP", name = "Deps" }
for _, t in ipairs{ "a", "b", "c", "d" } do T{ noun = "task", action = "create", project = "DEP", title = t } end
has(T{ noun = "deps", action = "add", key = "DEP-2", depends_on = "DEP-1" }, "depends on", "b depends on a")
T{ noun = "deps", action = "add", key = "DEP-3", depends_on = "DEP-2" }
iserr(T{ noun = "deps", action = "add", key = "DEP-1", depends_on = "DEP-3" }, "a cycle is refused")
iserr(T{ noun = "deps", action = "add", key = "DEP-1", depends_on = "DEP-1" }, "self-dependency refused")
iserr(T{ noun = "deps", action = "add", key = "DEP-1", depends_on = "BOG-2" }, "cross-project dependency refused")
local plan = tc.resolve_plan("DEP")
ok(#plan.ready == 2 and #plan.blocked == 2, "resolver: a and d ready, b and c blocked")
ok(#plan.layers == 3 and plan.layers[1][1] == "DEP-1" and plan.layers[3][1] == "DEP-3", "layers follow the chain")
has(T{ noun = "status", key = "DEP-1", status = "done" }, "now unblocked: DEP-2", "closing reports newly unblocked")
local json = require("json")
local pj = json.decode(T{ noun = "deps", action = "resolve", project = "DEP", format = "json" })
ok(pj and pj.ready and #pj.ready == 2, "format=json plan")
T{ noun = "task", action = "breakdown", key = "DEP-4", subtasks = "child" }
local wp = tc.resolve_plan("DEP")
local waiting = false
for _, x in ipairs(wp.waiting) do if x.key == "DEP-4" then waiting = true end end
ok(waiting, "a parent with an open child is waiting, not ready")
has(T{ noun = "deps", action = "resolve", goal = "DEP-3" }, "Plan for DEP → DEP-3", "goal-narrowed plan infers the project")

-- ---- tags ------------------------------------------------------------------------------------
has(T{ noun = "tag", action = "rule_add", tag = "auth", match_regex = "log(in|out)" }, "→ auth", "regex rule added")
has(T{ noun = "tag", action = "rule_add", tag = "spike-work", match_kind = "spike", project = "BOG" }, "→ spike-work", "kind rule")
iserr(T{ noun = "tag", action = "rule_add", tag = "x" }, "a rule needs a matcher")
has(T{ noun = "task", action = "create", project = "BOG", title = "Fix LOGIN redirect" }, "auto-tags: auth", "regex rule applies case-insensitively")
has(T{ noun = "task", action = "create", project = "BOG", title = "Try a thing", kind = "spike" }, "spike-work", "kind rule applies")
has(T{ noun = "tag", action = "add", key = "BOG-2", tag = "ui" }, "Tagged", "manual tag")
has(T{ noun = "query", view = "tasks", tag = "ui" }, "BOG-2", "query by tag")

-- ---- commits ------------------------------------------------------------------------------------
has(T{ noun = "commits", action = "link", key = "BOG-2", commit = "abc1234def", message = "fix it" }, "Linked", "link a commit")
has(T{ noun = "commits", action = "link", key = "BOG-2", commit = "abc1234def" }, "Already linked", "linking is idempotent")

-- ---- queries ---------------------------------------------------------------------------------------
has(T{ noun = "query", view = "tree", project = "BOG" }, "  - `BOG-3`", "tree indents children")
has(T{ noun = "query", view = "rollup", project = "STR" }, "criteria: 1/1 passing", "rollup")
has(T{ noun = "query", view = "tasks", project = "BOG", status = "in_review" }, "BOG-2", "status filter")
local many = T{ noun = "query", view = "tasks", limit = 999 }
ok(select(2, many:gsub("\n", "")) <= tc.MAX_LIMIT, "limit capped at " .. tc.MAX_LIMIT)
iserr(T{ noun = "query", view = "nope" }, "unknown view refused")
iserr(T{ noun = "task", action = "explode" }, "unknown action lists the valid set")
has(T{ noun = "task", action = "explode" }, "breakdown|create|get|move|update", "valid actions named")
iserr(T{ noun = "widget" }, "unknown noun refused")

-- ---- backend routing ---------------------------------------------------------------------------------
ok(tc.backend() == "native", "default backend is native")
local calls = {}
package.loaded.stationlink = { active = function() return true end,
  call = function(tool, p) calls[#calls + 1] = { tool = tool, p = p }; return "station says hi" end }
tc.set_backend("station")
ok(tc.call{ noun = "project", action = "list" } == "station says hi", "station backend passes through")
ok(calls[1].tool == "tracker" and calls[1].p.noun == "project", "as station's own `tracker` tool")
tc.call{ noun = "status", key = "X-1", status = "done", override = true, priority = 2 }
ok(calls[2].p.override == "true" and calls[2].p.priority == 2 and calls[2].p.backend == nil,
   "booleans become strings, integers stay, `backend` is stripped")
ok(tc.call{ noun = "project", action = "list", backend = "native" }:find("BOG", 1, true), "per-call backend override")
package.loaded.stationlink = { active = function() return false end }
iserr(tc.call{ noun = "project", action = "list" }, "station down is an error, never a silent native write")
tc.set_backend("native")
package.loaded.stationlink = nil

-- ---- import from ai-grind ------------------------------------------------------------------------------
do
  local path = bog.userdir .. "/aig.db"
  os.remove(path)  -- the fixture is rebuilt each run (ctest keeps the suite's HOME)
  local src = db.open(path)
  for _, sql in ipairs{
    "CREATE TABLE projects(id INTEGER PRIMARY KEY, key TEXT, name TEXT, description TEXT, close_policy TEXT, next_seq INTEGER, created_at TEXT)",
    "CREATE TABLE tasks(id INTEGER PRIMARY KEY, project_id INT, key TEXT, parent_id INT, depth INT, kind TEXT, title TEXT, description TEXT, status TEXT, priority INT, sort_order REAL, created_at TEXT, updated_at TEXT, closed_at TEXT, uid TEXT)",
    "CREATE TABLE acceptance_criteria(id INTEGER PRIMARY KEY, task_id INT, text TEXT, test_ref TEXT, last_result TEXT, last_run_at TEXT, created_at TEXT, uid TEXT)",
    "CREATE TABLE task_deps(task_id INT, depends_on_id INT, created_at TEXT)",
    "CREATE TABLE tags(id INTEGER PRIMARY KEY, name TEXT)",
    "CREATE TABLE task_tags(task_id INT, tag_id INT)",
    "CREATE TABLE tag_rules(id INTEGER PRIMARY KEY, project_id INT, tag_id INT, match_kind TEXT, match_regex TEXT, match_parent_kind TEXT, enabled INT, created_at TEXT)",
    "CREATE TABLE task_commits(id INTEGER PRIMARY KEY, task_id INT, commit_hash TEXT, repo_path TEXT, message_snippet TEXT, linked_at TEXT)",
    "INSERT INTO projects VALUES(1,'AIG','From ai-grind','','strict',4,'2026-08-08T13:19:26.350718+00:00')",
    "INSERT INTO projects VALUES(2,'BOG','clash','','advisory',2,'2026-08-08T13:19:26+00:00')",
    "INSERT INTO tasks VALUES(10,1,'AIG-1',NULL,0,'epic','Parent','', 'in_progress',2,1,'2026-08-08T13:19:26+00:00','2026-08-09T00:00:00+00:00',NULL,'u10')",
    "INSERT INTO tasks VALUES(11,1,'AIG-2',10,1,'story','Child','', 'done',3,1,'2026-08-08T13:19:26+00:00','2026-08-09T00:00:00+00:00','2026-08-10T00:00:00+00:00','u11')",
    "INSERT INTO tasks VALUES(12,1,'AIG-3',NULL,0,'task','Later','', 'open',3,2,'2026-08-08T13:19:26+00:00','2026-08-09T00:00:00+00:00',NULL,'u12')",
    "INSERT INTO acceptance_criteria VALUES(1,11,'passes','tests/a::b','pass','2026-08-10T00:00:00+00:00','2026-08-08T00:00:00+00:00','c1')",
    "INSERT INTO task_deps VALUES(12,10,'2026-08-08T00:00:00+00:00')",
    "INSERT INTO tags VALUES(1,'core')", "INSERT INTO task_tags VALUES(10,1)",
    "INSERT INTO tag_rules VALUES(1,1,1,'spike','','',1,'2026-08-08T00:00:00+00:00')",
    "INSERT INTO task_commits VALUES(1,11,'deadbeef','/repo','AIG-2 done','2026-08-10T00:00:00+00:00')",
  } do src:run(sql) end
  src:close()
  local out = T{ noun = "import", path = path }
  has(out, "Imported 1 project(s)", "import brings in the new project")
  has(out, "3 tasks, 1 criteria, 1 deps, 1 tags, 1 tag rules, 1 commit links", "with everything attached")
  has(out, "skipped (already in the native tracker): BOG", "an existing project is skipped, not merged")
  local g = T{ noun = "task", action = "get", key = "AIG-2" }
  has(g, "parent: `AIG-1`", "hierarchy survives the id remap")
  has(g, "status=done", "status kept")
  has(g, "[x]", "criterion result kept")
  has(g, "deadbeef", "commit link kept")
  has(T{ noun = "project", action = "get", key = "AIG" }, "policy: strict · next: `AIG-4`", "policy and next_seq kept")
  has(T{ noun = "task", action = "create", project = "AIG", title = "new" }, "`AIG-4`", "new keys continue the sequence")
  has(T{ noun = "deps", action = "list", key = "AIG-3" }, "AIG-1", "dependency kept")
  has(T{ noun = "import", path = path }, "skipped (already in the native tracker): AIG, BOG", "a second import skips both")
  iserr(T{ noun = "import", path = bog.userdir .. "/nope.db" }, "a missing source is an error")
  local iso = require("tracker_import").iso_to_epoch
  ok(iso("1970-01-01T00:00:10+00:00") == 10, "ISO epoch start")
  ok(iso("2026-08-08T13:19:26.350718+00:00") == 1786195166, "a real ai-grind timestamp")
  ok(iso("2026-01-15T12:00:00+01:00") == iso("2026-01-15T11:00:00+00:00"), "an explicit offset is honoured")
  ok(iso("2000-02-29T00:00:00Z") == 951782400, "leap day")
end

-- ---- GitHub issues through gh (a fake gh records every call) -------------------------------
do
  local dir = bog.userdir
  local log = dir .. "/gh.log"
  os.remove(log); os.remove(dir .. "/gh-closed-42"); os.remove(dir .. "/gh-closed-7")
  local fake = dir .. "/fake-gh"
  local f = io.open(fake, "w")
  f:write([[#!/bin/sh
D="$(dirname "$0")"
{ printf 'CALL'; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } >> "$D/gh.log"
case "$1 $2" in
  "repo view") echo "acme/widgets" ;;
  "label list") printf 'bug\nui\n' ;;
  "issue create")
    while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && { echo "BODY:"; cat "$2"; echo; } >> "$D/gh.log"; shift; done
    echo "https://github.com/acme/widgets/issues/42" ;;
  "issue view")
    if [ -f "$D/gh-closed-$3" ]; then S=CLOSED; else S=OPEN; fi
    [ "$3" = "9" ] && S=MERGED
    [ "$3" = "404" ] && { echo "GraphQL: Could not resolve to an issue" ; exit 1; }
    printf '{"state":"%s","title":"t","url":"https://github.com/acme/widgets/issues/%s"}\n' "$S" "$3" ;;
  "issue close") touch "$D/gh-closed-$3"; echo "Closed issue #$3" ;;
  *) echo "unexpected gh call" ; exit 2 ;;
esac
]])
  f:close()
  os.execute("chmod +x '" .. fake .. "'")
  local real_gh = tc.GH
  tc.GH = fake
  local function gh_log() local h = io.open(log); local s2 = h and h:read("a") or ""; if h then h:close() end; return s2 end

  T{ noun = "project", action = "create", key = "GH", name = "GitHub" }
  T{ noun = "task", action = "create", project = "GH", title = "It's got a 'quote' in it", description = "Body text." }
  T{ noun = "criteria", action = "add", key = "GH-1", text = "works", test_ref = "tests/a::b" }
  T{ noun = "tag", action = "add", key = "GH-1", tag = "ui" }
  T{ noun = "tag", action = "add", key = "GH-1", tag = "not-a-label-there" }
  local out = T{ noun = "issue", action = "create", key = "GH-1" }
  has(out, "Created acme/widgets#42", "issue create files through gh, repo auto-detected")
  has(out, "(labels: ui)", "only labels the repo already has are applied")
  local l = gh_log()
  has(l, "<--title> <[GH-1] It's got a 'quote' in it>", "a quote in the title survives the shell")
  ok(not l:find("not-a-label-there", 1, true), "an unknown label is never sent (gh would refuse the call)")
  has(l, "- [ ] works (`tests/a::b`)", "the body carries the criteria checklist")
  has(l, "Tracked as `GH-1`", "and a back-reference")
  has(T{ noun = "issue", action = "create", key = "GH-1" }, "already has acme/widgets#42", "create is idempotent")
  has(T{ noun = "issue", action = "sync", key = "GH-1" }, "in sync with acme/widgets#42 (OPEN)", "sync when both open")
  T{ noun = "status", key = "GH-1", status = "done", override = true }
  has(T{ noun = "issue", action = "sync", project = "GH" }, "DRIFT: the ticket is done but acme/widgets#42 is still open", "drift: closed locally")
  has(T{ noun = "issue", action = "close", key = "GH-1" }, "Closed acme/widgets#42", "close through gh")
  has(gh_log(), "Closed from boggart: `GH-1` is done.", "close leaves a comment saying why")
  has(T{ noun = "issue", action = "sync", key = "GH-1" }, "in sync with acme/widgets#42 (CLOSED)", "in sync after closing")
  T{ noun = "task", action = "create", project = "GH", title = "second" }
  has(T{ noun = "issue", action = "link", key = "GH-2", number = 7 }, "Linked `GH-2` to acme/widgets#7 (OPEN)", "link an existing issue")
  io.open(dir .. "/gh-closed-7", "w"):close()
  has(T{ noun = "issue", action = "sync", key = "GH-2" }, "DRIFT: acme/widgets#7 is closed on GitHub but the ticket is open", "drift: closed remotely")
  iserr(T{ noun = "issue", action = "link", key = "GH-2", number = 404, repo = "acme/widgets" }, "a missing issue is an error")
  T{ noun = "task", action = "create", project = "GH", title = "a PR" }
  T{ noun = "issue", action = "link", key = "GH-3", number = 9 }
  has(T{ noun = "issue", action = "sync", key = "GH-3" }, "DRIFT: acme/widgets#9 is closed on GitHub", "a MERGED pull request counts as closed")
  iserr(T{ noun = "issue", action = "sync", key = "GH-99" }, "unknown ticket")
  has(T{ noun = "query", view = "issues", project = "GH" }, "`GH-1` (done) → acme/widgets#42 CLOSED", "issues view")
  T{ noun = "task", action = "create", project = "GH", title = "fourth, never filed" }
  tc.GH = "/nonexistent/gh"
  iserr(T{ noun = "issue", action = "create", key = "GH-4", repo = "acme/widgets" }, "no gh binary is an error, not a raise")
  tc.GH = real_gh
end

-- ---- the committed tracker file, JUnit results, the CLI (CI) -------------------------------
do
  local tf, cli = require("tracker_file"), require("tracker_cli")
  local dir = bog.userdir
  local function read(p) local h = io.open(p); local x = h:read("a"); h:close(); return x end
  local f1, f2 = dir .. "/t1.jsonl", dir .. "/t2.jsonl"
  ok(tf.export(f1, { "BOG", "DEP" }), "export two projects")
  ok(tf.export(f2, { "BOG", "DEP" }), "export again")
  ok(read(f1) == read(f2), "export is deterministic")
  local first = read(f1):match("^[^\n]+")
  ok(first == '{"format":1,"t":"meta"}', "a meta line leads: " .. tostring(first))
  ok(not read(f1):find('"id"', 1, true), "no database ids in the file")
  -- round trip: wipe the two projects, import, export -> identical bytes
  T{ noun = "project", action = "create", key = "KEEP", name = "untouched by the import" }
  bog.db:run("DELETE FROM trk_projects WHERE key IN ('BOG','DEP')")
  bog.db:run("DELETE FROM trk_tasks WHERE project IN ('BOG','DEP')")
  local imp = tf.import(f1)
  has(imp, "Imported 2 project(s)", "import the file")
  ok(tf.export(f2, { "BOG", "DEP" }) and read(f1) == read(f2), "export -> import -> export is byte-identical")
  has(T{ noun = "task", action = "get", key = "BOG-3" }, "parent: `BOG-1`", "hierarchy survives the file")
  has(T{ noun = "deps", action = "list", key = "DEP-3" }, "DEP-2", "dependencies survive the file")
  ok(tc.project_row("KEEP") ~= nil, "a project not in the file is left alone")
  -- the file replaces the projects it names
  T{ noun = "task", action = "create", project = "BOG", title = "added after export" }
  tf.import(f1)
  ok(not T{ noun = "query", view = "tasks", project = "BOG", title_pattern = "added after export" }:find("added after", 1, true),
     "importing replaces a project wholesale (the file is the truth for it)")
  local bad = dir .. "/bad.jsonl"
  local h = io.open(bad, "w"); h:write('{"t":"project","key":"X"}\n'); h:close()
  local r0, e0 = tf.import(bad)
  ok(r0 == nil and e0:find("meta"), "a file without its meta line is refused")

  -- JUnit
  local junit = dir .. "/junit.xml"
  h = io.open(junit, "w")
  h:write([[<?xml version="1.0"?><testsuites><testsuite name="s">
<testcase classname="config" name="parses" time="0.1"/>
<testcase classname="tests.config" name="rejects" file="tests/config_test.py"><failure message="boom">x</failure></testcase>
<testcase classname="config" name="skipped_one"><skipped/></testcase>
<testcase name="tracker" classname="tracker" status="fail"><failure/></testcase>
</testsuite></testsuites>]])
  h:close()
  local cases = tf.parse_junit(read(junit))
  ok(#cases == 4 and cases[1].result == "pass" and cases[2].result == "fail" and cases[3].result == nil,
     "parse testcases: pass, fail, skipped")
  ok(tf.ref_matches("config::parses", cases[1]), "classname::name")
  ok(tf.ref_matches("tests/config_test.py::rejects", cases[2]), "file::name")
  ok(tf.ref_matches("parses", cases[1]), "bare name")
  ok(not tf.ref_matches("other::parses", cases[1]), "a different prefix does not match")
  T{ noun = "project", action = "create", key = "JU", name = "junit" }
  T{ noun = "task", action = "create", project = "JU", title = "t" }
  T{ noun = "criteria", action = "add", key = "JU-1", text = "parses", test_ref = "config::parses" }
  T{ noun = "criteria", action = "add", key = "JU-1", text = "rejects", test_ref = "tests/config_test.py::rejects" }
  T{ noun = "criteria", action = "add", key = "JU-1", text = "ctest suite", test_ref = "tracker" }
  T{ noun = "criteria", action = "add", key = "JU-1", text = "nowhere", test_ref = "missing::case" }
  has(tf.record_junit(junit), "2 fail", "record from JUnit")
  local cl = T{ noun = "criteria", action = "list", key = "JU-1" }
  ok(cl:find("[x] #", 1, true) and cl:find("[!] #", 1, true), "pass and fail marks recorded")
  has(tf.record_junit(junit, { "JU" }), "1 linked criteria had no matching testcase", "unmatched refs are reported, per project")

  -- closing keywords, in a real git repository
  local repo = string.format("%s/repo-%d-%d", dir, os.time(), math.random(1, 1e9))  -- fresh each run
  os.execute("mkdir -p '" .. repo .. "' && cd '" .. repo .. "' && git init -q"
    .. " && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'wip JU-1'"
    .. " && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'Fixes ju-1: done now'")
  has(T{ noun = "commits", action = "scan", repo = repo }, "Scanned 2 commits", "scan without keywords")
  has(T{ noun = "task", action = "get", key = "JU-1" }, "status=open", "no keywords -> no transition")
  local closed = T{ noun = "commits", action = "scan", repo = repo, close_keywords = true }
  has(closed, "`JU-1` [task/done]", "'Fixes ju-1' closes the ticket (case-insensitive)")

  -- CLI
  local out, code = cli.run{ "project", "list" }
  ok(code == 0 and out:find("JU", 1, true), "cli: noun action")
  out, code = cli.run{ "status", "key=JU-1", "status=nope" }
  ok(code == 1 and out:find("^Error:"), "cli: an error exits 1")
  out, code = cli.run{ "task", "create", "project=JU", "oops" }
  ok(code == 1, "cli: a malformed argument exits 1")
  out, code = cli.run{ "JU" }
  ok(code == 0 and out:find("JU ", 1, true), "cli: display form")
  out, code = cli.run{ "export-file", dir .. "/cli.jsonl", "project=JU" }
  ok(code == 0 and out:find("Exported 1 project", 1, true), "cli: export-file with a project filter")
  out, code = cli.run{ "record-junit" }
  ok(code == 1, "cli: record-junit without a path exits 1")
end

-- ---- display (lua/tracker_view.lua) ----------------------------------------------------
do
  local v = require("tracker_view")
  local function width_ok(text, w, name)
    local worst = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do worst = math.max(worst, v.display_width(line)) end
    ok(worst <= w, name .. " fits " .. w .. " columns (widest " .. worst .. ")")
  end
  T{ noun = "project", action = "create", key = "VIEW",
     name = "A project with a deliberately long name that will not fit beside its counts" }
  T{ noun = "task", action = "create", project = "VIEW", title = "Short one", priority = 1 }
  T{ noun = "task", action = "create", project = "VIEW",
     title = "A very long title that has to wrap underneath itself instead of being cut off at the edge of the terminal",
     description = "#### VIEW-2 — the heading that repeats the title\n\n**Status:** in progress.\n" .. string.rep("line of detail\n", 40) }
  T{ noun = "task", action = "create", project = "VIEW", title = "Waits" }
  T{ noun = "deps", action = "add", key = "VIEW-3", depends_on = "VIEW-2" }
  T{ noun = "status", key = "VIEW-2", status = "in_progress" }
  T{ noun = "criteria", action = "add", key = "VIEW-2", text = "short", test_ref = "tests/t::a" }
  T{ noun = "criteria", action = "add", key = "VIEW-2",
     text = "a criterion written as a whole sentence, the way real ones usually are, which cannot sit in a column" }

  local m = v.next_model("VIEW")
  ok(m and m.sections[1].title == "In progress" and m.sections[1].rows[1].key == "VIEW-2", "in progress leads")
  local titles = {}
  for _, sct in ipairs(m.sections) do titles[#titles + 1] = sct.title end
  ok(table.concat(titles, ",") == "In progress,Ready,Blocked", "sections in working order: " .. table.concat(titles, ","))
  local blocked = m.sections[3].rows[1]
  ok(blocked.key == "VIEW-3" and blocked.glyph == v.GLYPH.blocked and blocked.note == "waits on VIEW-2",
     "a dependency-blocked ticket shows the blocked glyph and what it waits on")

  for _, w in ipairs{ 40, 60, 100 } do
    width_ok(v.command("VIEW", w), w, "what's next")
    width_ok(v.command("VIEW-2", w), w, "card")
    width_ok(v.command("VIEW tree", w), w, "tree")
    width_ok(v.command("", w), w, "projects")
  end
  local next80 = v.command("VIEW", 80)
  has(next80, "VIEW-2  P3 task    A very long title", "rows lead with the key")
  ok(not next80:find("…", 1, true), "titles wrap rather than truncate")

  local card = v.command("VIEW-2", 80)
  ok(not card:find("####", 1, true) and not card:find("**", 1, true), "markdown noise stripped from the card")
  ok(not card:find("the heading that repeats", 1, true), "a heading repeating the key is dropped")
  has(card, "more lines (/tracker VIEW-2 full)", "long descriptions are trimmed with a pointer")
  has(v.command("VIEW-2 full", 80), "line of detail", "full shows the rest")
  has(card, "Acceptance  0 of 2 passing", "criteria summary")
  has(card, "↳ tests/t::a", "long criteria move their test ref beneath")
  has(card, "Blocks      VIEW-3", "blocks field")
  has(v.command("NOPE-1", 80), "no such ticket", "unknown ticket")
  has(v.command("help", 80), "/tracker <PROJECT>", "help")

  local b = v.board_model("VIEW")
  ok(#b.columns == 6 and b.columns[2].status == "in_progress" and b.columns[2].rows[1].key == "VIEW-2",
     "board columns follow the status workflow")
end

io.write(string.format("tracker: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
