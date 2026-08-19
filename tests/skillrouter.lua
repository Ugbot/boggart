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

sys.rmtree(bog.userdir)
bog.userdir = saved_userdir

io.write(string.format("skillrouter: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
