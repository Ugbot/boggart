-- scopes.lua -- tool scopes (§9) and provenance/usage accounting (§17, §24).
--
-- The paper's argument for scopes is that global persistence is the one to be
-- careful with, and that project scope is what makes "a later session starts
-- with better operational knowledge than the first" actually true. boggart had
-- exactly one scope before this, and it was the global one.
--
-- The argument for the counters is sharper: a tool costing 2,000 tokens to
-- build that saves 50 once is noise, while one that removes four round trips on
-- each of twenty later calls is infrastructure -- and nothing can tell those
-- apart without measuring.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_scopes"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()
bog.session.id = 4242

local T = bog.tools

-- ---- project identity ----
local root = T.project_root()
ok(type(root) == "string" and #root > 0, "project_root returns a path")
eq(sys.stat(root), "dir", "project root is a real directory")
eq(T.project_root(), root, "project_root is stable across calls")
-- The bucket must live under the user's own directory, never inside the repo:
-- a tool committed to a checkout would be executable code injected into anyone
-- who runs an agent there (paper §16.7).
ok(T.tools_dir("project"):find(bog.userdir, 1, true) == 1,
   "project tools are stored under the user dir, not in the repository")
ok(T.tools_dir("project") ~= T.tools_dir("global"), "project and global buckets differ")
ok(T.tools_dir("project"):find("boggart", 1, true) ~= nil,
   "the bucket name is recognisable (basename + digest)")

-- ---- the three scopes ----
eq(T.run("define_tool", { name = "s_tool", description = "session", scope = "session",
                          lua = "return 'S'" }):find("session") ~= nil, true,
   "session scope is reported back")
T.run("define_tool", { name = "p_tool", description = "project", lua = "return 'P'" })
T.run("define_tool", { name = "g_tool", description = "global", scope = "global",
                       lua = "return 'G'" })

eq(T.run("s_tool", {}), "S", "session tool runs")
eq(T.run("p_tool", {}), "P", "project tool runs")
eq(T.run("g_tool", {}), "G", "global tool runs")

eq(T.registry["p_tool"].scope, "project", "default scope is project")
eq(T.registry["p_tool"].project, root, "project tool records its project")
eq(T.registry["g_tool"].project, "", "global tool has no project")

-- ---- persistence follows the scope ----
eq(sys.stat(T.tools_dir("project") .. "/s_tool.lua"), nil, "session tool is NOT written to disk")
eq(sys.stat(T.tools_dir("project") .. "/p_tool.lua"), "file", "project tool is written to the project bucket")
eq(sys.stat(T.tools_dir("global") .. "/g_tool.lua"), "file", "global tool is written to the global bucket")
eq(sys.stat(T.tools_dir("global") .. "/p_tool.lua"), nil, "a project tool does not leak into global")

-- ---- a bad scope is a validation error, not a silent default ----
local bad = T.run("define_tool", { name = "x", description = "d", scope = "everywhere",
                                   lua = "return 1" })
ok(bad:find("[validation_error]", 1, true) ~= nil, "an unknown scope is rejected")
ok(bad:find("everywhere", 1, true) ~= nil, "the rejection names the offending scope")

-- ---- reload: project and global come back, session does not ----
package.loaded["tools"] = nil
bog.tools = require("tools")
T = bog.tools
ok(T.registry["p_tool"] ~= nil, "project tool survives a reload")
ok(T.registry["g_tool"] ~= nil, "global tool survives a reload")
eq(T.registry["s_tool"], nil, "session tool does NOT survive a reload")
eq(T.registry["p_tool"].scope, "project", "scope is restored from the bucket it was found in")

-- ---- project tools shadow global ones of the same name ----
-- More specific knowledge about *this* repository should beat a general helper.
T.run("define_tool", { name = "dual", description = "global one", scope = "global",
                       lua = "return 'from-global'" })
T.run("define_tool", { name = "dual", description = "project one", scope = "project",
                       lua = "return 'from-project'" })
package.loaded["tools"] = nil
bog.tools = require("tools")
T = bog.tools
eq(T.run("dual", {}), "from-project", "the project tool shadows the global one")

-- ---- provenance (§17) ----
local rows = bog.store.tool_stats(root)
local by = {}
for _, r in ipairs(rows) do by[r.name .. "/" .. r.scope] = r end
ok(by["p_tool/project"] ~= nil, "project tool was recorded")
ok(by["g_tool/global"] ~= nil, "global tool was recorded")
-- Read back explicitly rather than with an `or` fallback: the first version of
-- this assertion masked a real bug, because tool_stats did not SELECT the
-- column at all and `nil or 4242` happily passed.
eq(by["p_tool/project"].created_session, 4242, "creating session is recorded and returned")
ok(by["p_tool/project"].version ~= nil, "boggart version is recorded and returned")
ok(by["p_tool/project"].created > 0, "creation time is recorded")
ok(by["p_tool/project"].git_rev ~= nil, "the git revision at creation is recorded (staleness, §18)")
eq(by["g_tool/global"].git_rev, nil, "a global tool has no repository revision")

-- ---- usage accounting (§24) ----
for _ = 1, 7 do T.run("p_tool", {}) end
T.run("define_tool", { name = "flaky", description = "always fails", lua = "error('nope')" })
T.run("flaky", {}); T.run("flaky", {}); T.run("flaky", {})

local rows2 = bog.store.tool_stats(root)
local by2 = {}
for _, r in ipairs(rows2) do by2[r.name] = r end
ok(by2["p_tool"].calls >= 7, "calls are counted (" .. by2["p_tool"].calls .. ")")
eq(by2["p_tool"].failures, 0, "a healthy tool records no failures")
eq(by2["flaky"].calls, 3, "a failing tool still counts its calls")
eq(by2["flaky"].failures, 3, "failures are counted separately -- this is the health signal")
ok(by2["p_tool"].last_used > 0, "last_used is stamped")

-- Re-defining a tool must not wipe its history: the counters describe the
-- procedure, and losing them on every edit would defeat the measurement.
local before = by2["p_tool"].calls
T.run("define_tool", { name = "p_tool", description = "project v2", lua = "return 'P2'" })
local by3 = {}
for _, r in ipairs(bog.store.tool_stats(root)) do by3[r.name] = r end
eq(by3["p_tool"].calls, before, "re-defining a tool keeps its call history")
eq(T.run("p_tool", {}), "P2", "...but the new body takes effect")

-- ---- the report surfaces all of it ----
local rep = T.report({})
ok(rep:find("p_tool", 1, true) ~= nil, "report lists model-defined tools")
ok(rep:find("scope", 1, true) ~= nil, "report shows scope")
ok(rep:find("calls", 1, true) ~= nil, "report shows call counts")
ok(T.report({ name = "flaky" }):find("error('nope')", 1, true) ~= nil,
   "report can show a tool's source")
-- built-ins are not "learned" and should not clutter the learned list
ok(not rep:match("\nread%s+%w+%s+%d"), "built-in tools are excluded from the learned list")

if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
