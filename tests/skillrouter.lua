-- skillrouter.lua -- the skill router (lua/skillrouter.lua): FTS5/bm25 search
-- over the live skill corpus, scored by SQLite (store.skills_reindex/search),
-- exposed to the model as find_skill. Runs against the real store in a
-- throwaway HOME, over the real baked-in skills plus one defined here.
local router = require("skillrouter")
local skills = require("skills")
local tools = require("tools")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- Isolate the overlay so the defined skill never lands in a developer's home.
local saved_userdir = bog.userdir
bog.userdir = os.tmpname() .. "_router"
sys.mkdir_p(bog.userdir .. "/lua/skills")
package.path = bog.userdir .. "/lua/?.lua;" .. package.path

-- ---- corpus flattening -----------------------------------------------------
local rows = router.corpus()
ok(#rows > 0, "corpus contains the baked-in skills")
local byname = {}
for _, r in ipairs(rows) do byname[r.name] = r end
ok(byname.core and byname.core.tools:find("bash"), "corpus flattens tool names")

-- ---- store layer -----------------------------------------------------------
bog.store.skills_reindex(rows)
local n = bog.db:query("SELECT count(*) AS c FROM skills_fts")[1].c
ok(n == #rows, "reindex inserts one row per skill")
bog.store.skills_reindex(rows)
ok(bog.db:query("SELECT count(*) AS c FROM skills_fts")[1].c == n, "reindex is a rebuild, not an append")

-- ---- routing over the real skills ------------------------------------------
local hits = router.route("isolate parallel work in git worktrees", 5)
ok(hits and hits[1] and hits[1].name == "git_worktree", "worktree query ranks git_worktree first")
ok(hits[1].score > 0, "scores are positive (negated bm25)")

hits = router.route("remember durable facts across sessions", 5)
ok(hits[1].name == "memory", "memory query ranks the memory skill first")

hits = router.route("spawn sub-agents and await results", 5)
ok(hits[1].name == "orchestrate", "orchestration query ranks orchestrate first")

-- a skill defined THIS session is searchable immediately (rebuild-per-query)
assert(skills.save("spreadsheeter", { description = "wrangle spreadsheets",
  instructions = "csv columns rows formulas", tools = {} }))
hits = router.route("csv spreadsheets", 5)
ok(hits[1] and hits[1].name == "spreadsheeter", "a just-defined skill is found without any invalidation step")

-- punctuation/operators cannot break the MATCH expression
ok(pcall(router.route, 'a"b(c AND NOT', 5), "operator soup does not raise")

-- ---- the tool through the real registry ------------------------------------
ok(tools.registry.find_skill ~= nil, "find_skill is registered")
local out = tools.run("find_skill", { query = "isolate work in a git worktree" })
ok(out:find("git_worktree"), "find_skill surfaces the match")
ok(tools.run("find_skill", {}):find("requires 'query'"), "missing query is a typed error")
ok(tools.run("find_skill", { query = "zzznope" }):find("no skills match"), "no-match points at `skills`")

-- user-invoked skills stay out of the default corpus / find_skill
assert(skills.save("secret_grill", {
  description = "user only grilling interview stress test",
  instructions = "ask hard questions about the plan",
  tools = {}, invocation = "user",
}))
local corp = router.corpus()
local has_secret = false
for _, r in ipairs(corp) do if r.name == "secret_grill" then has_secret = true end end
ok(not has_secret, "corpus hides user-invoked skills by default")
ok(router.corpus({ include_user = true })[1] ~= nil, "include_user corpus is non-empty")
local with_user = false
for _, r in ipairs(router.corpus({ include_user = true })) do
  if r.name == "secret_grill" then with_user = true end
end
ok(with_user, "include_user surfaces user-invoked skills")
local hide = tools.run("find_skill", { query = "grilling interview stress" })
ok(not hide:find("secret_grill"), "find_skill hides user-invoked by default")
local show = tools.run("find_skill", { query = "grilling interview stress", include_user = true })
ok(show:find("secret_grill"), "find_skill include_user finds user-invoked")

-- gold model skills are findable
ok(tools.run("find_skill", { query = "test-driven red green refactor" }):find("tdd"),
   "find_skill surfaces tdd gold skill")

-- ---- auto-routing for the session's own agent ---------------------------------------
do
  -- pick(): pure selection rules
  local H = function(...) local t = {} for i = 1, select("#", ...), 2 do
    t[#t + 1] = { name = select(i, ...), score = select(i + 1, ...) } end return t end
  local s, why = router.pick("draft the next chapter of the story", nil, H("story_kb", 10, "world_check", 8.5, "handoff", 7.6, "tdd", 3))
  ok(s and #s == 2 and s[1] == "story_kb" and s[2] == "world_check", "pick: clear winners only (>= 80% of best; 76% is out)")
  ok(why:find("routed", 1, true), "pick: says why")
  s = router.pick("write a short scene for the novel", nil, H("a", 5, "b", 5, "c", 5, "d", 5))
  ok(#s == router.MAX, "pick: at most MAX skills")
  s = router.pick("fix the broken build script", nil, H("core", 9, "diagnosing_bugs", 8))
  ok(#s == 1 and s[1] == "diagnosing_bugs", "pick: core/comms are never routed (core is always added)")
  local cur = { "story_kb" }
  ok(router.pick("yes continue", cur, H("tdd", 9)) == cur, "pick: a short turn keeps the current set")
  ok(router.pick("yes", nil, H("tdd", 9)) == nil, "pick: a short first turn routes nothing")
  ok(router.pick("keep going with that then", cur, H("tdd", 9)) == cur, "pick: function words do not count as content")
  local rw = table.concat(router.route_words("Draft the NEXT chapter where Vera reaches the city"), " ")
  ok(rw == "draft chapter vera reaches city", "route_words drops function words -- got " .. rw)
  ok(router.pick("something nobody indexed at all", cur, {}) == cur, "pick: no match keeps the current set")
  ok(router.pick("something matching only weakly", nil, H("x", 0)) == nil, "pick: zero scores are not matches")
  ok(router.pick("check the canon for this scene", { "story_kb", "world_check" }, H("story_kb", 9, "tdd", 8))
     [2] == "world_check", "pick: hysteresis keeps the set while its best hit is loaded")
  s = router.pick("now fix the failing unit tests", cur, H("tdd", 9, "story_kb", 2))
  ok(#s == 1 and s[1] == "tdd", "pick: a clear topic shift replaces the set")

  -- off by default: nothing changes
  router._auto = nil
  local env = os.getenv("BOGGART_SKILL_ROUTE")
  if not env or env == "" then
    bog.store.kv_del(router.AUTO_KEY)
    ok(router.auto_enabled() == false, "auto-routing is off by default")
  end
  router._auto = false
  local sess = { id = "route-test", messages = {} }
  ok(router.select("draft the next chapter of the story", sess) == nil, "off: select routes nothing")
  local thread = require("thread")
  local rec = thread.session_agent(sess, nil, "draft the next chapter of the story")
  ok(#rec.skills == 0 and next(rec.allow) == nil and not rec.routed, "off: the agent keeps the whole registry")

  -- on: a story turn loads the story skills plus files+shell
  router.set_auto(true)
  ok(router.auto_enabled() and bog.store.kv_get(router.AUTO_KEY) == "on", "set_auto persists")
  local seen
  local events = require("events")
  local okon = pcall(events.on, "skills:routed", function(_, d) seen = d end)
  rec = thread.session_agent(sess, nil, "draft the next chapter of the novel where Vera opens the door")
  local set = {}
  for _, n in ipairs(rec.skills) do set[n] = true end
  ok(rec.routed and set.core and (set.story_kb or set.world_check or set.world_lookup),
    "on: a story turn routes to story skills, plus core -- got " .. table.concat(rec.skills, ","))
  ok(rec.allow.read and rec.allow.edit and rec.allow.story, "on: files, shell and the story tool are granted")
  ok(rec.allow.find_skill, "on: find_skill stays, so the agent can reach another skill")
  ok(not rec.allow.git_diff, "on: tools of unrelated skills are not offered")
  ok(rec.instructions:find("Skill: ", 1, true), "on: the routed skills' instructions are in the prompt")
  ok(sess.routed and sess.routed.why:find("routed", 1, true), "on: the choice is recorded on the session")
  if okon then ok(seen and seen.session == "route-test", "on: skills:routed is announced") end
  local before = sess.routed.skills
  rec = thread.session_agent(sess, nil, "ok")
  ok(sess.routed.skills == before and rec.routed, "on: a short follow-up keeps the same skills")

  -- explicit skills always win
  local mine = { id = "explicit", messages = {}, skills = { "tdd" } }
  rec = thread.session_agent(mine, nil, "draft the next chapter of the novel")
  ok(#rec.skills == 1 and rec.skills[1] == "tdd" and not rec.routed, "explicit session skills are never overridden")

  -- keywords: validated, and indexed
  ok(skills.validate({ keywords = "story" }) ~= nil, "keywords must be a list")
  ok(skills.validate({ keywords = { "story", "" } }) ~= nil, "keywords may not be empty strings")
  ok(skills.validate({ keywords = { "story" } }) == nil, "a keywords list is valid")
  local krows = router.corpus()
  for _, r in ipairs(krows) do
    if r.name == "story_kb" then ok(r.tools:find("chapter", 1, true), "keywords are indexed with the tools") end
  end
  router.set_auto(false)
  bog.store.kv_del(router.AUTO_KEY)
  router._auto = nil
end

sys.rmtree(bog.userdir)
bog.userdir = saved_userdir

io.write(string.format("skillrouter: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
