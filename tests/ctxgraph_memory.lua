-- tests/ctxgraph_memory.lua -- the one memory setting: BOGGART_MEMORY / --memory.
--
--   summary   prose-summary compaction (default)
--   local     graph memory, minimal SQLite backend
--   <name>    graph memory on a backend an extension registered as <name>
--
-- Each value; a name nothing registered refused as not built in and not
-- installed (headless exits 2 before any request, the REPL falls back to
-- summary); a fake registered as `example` selected and actually used; a backend module loaded from the Lua path at
-- runtime; and the lower-level switches losing to BOGGART_MEMORY.
-- Run: boggart --eval tests/ctxgraph_memory.lua
bog.store.open()
dofile("tests/ctxgraph_fresh.lua")({ 601 })
local RF = require("runflags")
local cg = require("ctxgraph")
local fake = dofile("tests/ctxgraph_fakebackend.lua")
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local function env(t) return function(k) return t[k] end end

-- ---- values ---------------------------------------------------------------------
local s = assert(RF.read({}, env{}, "headless"))
eq(s.memory, nil, "nothing given: nothing set (summary by default)")
eq(cg.resolve(nil, env{}).mode, "summary", "the default tier is summary")
s = assert(RF.read({ memory = "local" }, env{}, "headless"))
eq(s.memory, "local", "--memory local")
s = assert(RF.read({}, env{ BOGGART_MEMORY = "LOCAL" }, "headless"))
eq(s.memory, "local", "BOGGART_MEMORY, case-folded")
s = assert(RF.read({ memory = "summary" }, env{ BOGGART_MEMORY = "local" }, "headless"))
eq(s.memory, "summary", "the flag beats the environment")
local t = cg.resolve("local", env{})
ck(t.mode == "graph" and t.backend == "sqlite", "local is graph memory on sqlite")

local _, err = RF.read({}, env{ BOGGART_MEMORY = "bogus" }, "headless")
ck(err and err:find("BOGGART_MEMORY", 1, true) and err:find("is not built in (summary, local)", 1, true)
  and err:find("no backend named 'bogus' is installed", 1, true),
  "a tier that is neither built in nor installed is refused, naming the built-in ones: " .. tostring(err))
-- core names no extension tier: nothing is special about any other name
ck(cg.EXTENSION_TIERS == nil, "core keeps no list of extension tier names")

-- ---- example, not installed ----------------------------------------------------------
cg.unregister_backend("example")
_, err = RF.read({}, env{ BOGGART_MEMORY = "example" }, "headless")
ck(err and err:find("example", 1, true) and err:find("no backend named 'example' is installed", 1, true),
  "example with no backend: not installed: " .. tostring(err))
s = assert(RF.read({}, env{ BOGGART_MEMORY = "example" }, "repl"))
eq(s.memory, "summary", "the REPL says so and stays on summary")
s = assert(RF.read({}, env{ BOGGART_MEMORY = "bogus" }, "repl"))
eq(s.memory, "summary", "...for any name it cannot find")

-- ...and a headless run stops with exit 2 before any request (the endpoint is
-- a closed port: had a request been made, the error would be a different one)
local bin = os.getenv("BOGGART_TEST_BIN") or "./boggart"
local home = bog.userdir .. "/headless-home"
local r = sys.exec(string.format("BOGGART_HOME=%q BOGGART_MEMORY=example ANTHROPIC_BASE_URL=http://127.0.0.1:9 "
  .. "ANTHROPIC_API_KEY=x %q -p hello 2>&1", home, bin), 60)
eq(r.code, 2, "headless -p with BOGGART_MEMORY=example exits 2")
ck(r.out:find("BOGGART_MEMORY", 1, true) and r.out:find("example", 1, true), "...naming the setting: " .. r.out:sub(1, 200))

-- ---- a fake registered as example is selected and used ------------------------------------
local g = fake()
ck(cg.register_backend("example", g), "an extension registers a backend under example")
s = assert(RF.read({}, env{ BOGGART_MEMORY = "example" }, "headless"))
eq(s.memory, "example", "example is now accepted")
local sess = { id = 601, model = "mock", memory = "example", messages = dofile("tests/ctxgraph_fixture.lua")(),
               context_limit = 8000, compact_ratio = 0.01 }
ck(cg.enabled(sess), "the session is on graph memory")
ck(bog.api.compact(sess, { stream = function() error("no model call") end, system = function() return "" end }), "compacted")
eq(g.calls.put_nodes, 1, "the registered backend got the compaction's records, in one put_nodes")
eq(g.calls.put_edges, nil, "...its edges carried as the records' links, no separate put_edges")
eq(#require("ctxgraph.sqlite").scan("601"), 0, "nothing went to the sqlite backend")
ck(#g.scan("601", { "span" }) > 0, "spans are in the registered backend")
cg.unregister_backend("example")

-- ---- a backend module loaded at runtime from the Lua path --------------------------------
local dir = bog.userdir .. "/extlua"
sys.mkdir_p(dir .. "/ctxgraph/backends")
require("util").write_file(dir .. "/ctxgraph/backends/scratchmem.lua",
  "return dofile('tests/ctxgraph_fakebackend.lua')()\n")
package.path = dir .. "/?.lua;" .. package.path
local rt = cg.resolve("scratchmem", env{})
ck(rt and rt.backend == "scratchmem" and rt.mode == "graph", "BOGGART_MEMORY=<name> loads ctxgraph.backends.<name>")

-- ---- the lower-level switches ---------------------------------------------------------------
t = cg.resolve(nil, env{ BOGGART_COMPACT = "graph" })
ck(t.mode == "graph" and t.backend == "sqlite", "BOGGART_COMPACT=graph alone: graph on sqlite")
_, err = RF.read({}, env{ BOGGART_COMPACT = "bogus" }, "headless")
ck(err and err:find("BOGGART_COMPACT", 1, true), "a bad BOGGART_COMPACT is refused")
local logged = {}
local old_log = bog.log
bog.log = function(m) logged[#logged + 1] = m end
t = cg.resolve(nil, env{ BOGGART_MEMORY = "summary", BOGGART_COMPACT = "graph" })
bog.log = old_log
eq(t.mode, "summary", "BOGGART_MEMORY wins over BOGGART_COMPACT")
ck(logged[1] and logged[1]:find("overrides", 1, true), "...and the conflict is logged")

if fails == 0 then io.write("ok  ctxgraph_memory: BOGGART_MEMORY picks the tier\n")
else io.write(string.format("FAIL ctxgraph_memory: %d check(s) failed\n", fails)); os.exit(1) end
