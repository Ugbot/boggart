-- route.lua -- which model, on which endpoint, over which wire.
--
-- `model` was per-session while the endpoint, the wire and the key were global,
-- so "use a different model" only worked if the other model happened to live on
-- the same server behind the same protocol. A fleet could not put a cheap local
-- critic next to a strong cloud coder -- the obvious thing to want the moment
-- there is more than one agent.
--
-- A route is the whole destination { model, url, wire }, resolved per request.
-- The credential still never enters Lua: the request names a url and a wire,
-- and C picks the key registered for that endpoint (boggart_auth_header_for in
-- src/lauth.c). These tests pin the resolution rules; the C half is exercised
-- by every real turn.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_route"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local route = require "route"
local presets = require "presets"

-- Two named destinations: a local server on the OpenAI wire and a cloud one on
-- the Anthropic wire. This is the case the whole feature exists for.
presets.save{
  ds4   = { url = "http://127.0.0.1:8000", wire = "anthropic", model = "deepseek-v4" },
  local_qwen = { url = "http://127.0.0.1:8080", wire = "openai", model = "qwen3.8-27b" },
  cheap = { url = "http://127.0.0.1:8080", wire = "openai", model = "qwen3.8-4b" },
}

-- ---- nil: the configured endpoint, unchanged -----------------------------
local cur = route.resolve(nil)
ok(cur ~= nil, "a nil spec resolves to the current destination")
eq(cur.name, "current", "and says so")
eq(route.resolve("").name, cur.name, "an empty spec resolves the same as nil")
eq(route.resolve("").model, cur.model, "to the same model")

-- ---- a bare model id: same endpoint, different model ---------------------
local m = route.resolve("claude-opus-5")
eq(m.model, "claude-opus-5", "a bare id is taken as a model")
eq(m.url, cur.url, "and stays on the configured endpoint")
eq(m.wire, cur.wire, "and the configured wire")
eq(m.name, "model", "labelled as a bare model")

-- ---- a preset name: the whole destination --------------------------------
local p = route.resolve("ds4")
eq(p.model, "deepseek-v4", "a preset name brings its model")
eq(p.url, "http://127.0.0.1:8000", "and its endpoint")
eq(p.wire, "anthropic", "and its wire")
eq(p.name, "ds4", "and keeps its name")

local q = route.resolve("local_qwen")
eq(q.wire, "openai", "a second preset resolves independently")
eq(q.url, "http://127.0.0.1:8080", "to its own endpoint")

-- The mixed fleet, in one assertion: two agents, two providers, two wires.
ok(p.url ~= q.url and p.wire ~= q.wire,
   "two agents can be routed to different endpoints on different wires")

-- ---- preset/model: that endpoint, a different model ----------------------
local o = route.resolve("ds4/deepseek-v4-pro")
eq(o.model, "deepseek-v4-pro", "preset/model overrides the model")
eq(o.url, "http://127.0.0.1:8000", "and keeps the preset's endpoint")
eq(o.wire, "anthropic", "and the preset's wire")

-- ---- a table: spelled out -------------------------------------------------
local t = route.resolve{ model = "x", url = "http://example.test", wire = "openai" }
eq(t.model, "x", "a table is taken as written")
eq(t.url, "http://example.test", "with its endpoint")
eq(t.wire, "openai", "and its wire")
local partial = route.resolve{ model = "y" }
eq(partial.model, "y", "a partial table keeps its model")
eq(partial.url, cur.url, "and falls back for what it omits")

-- ---- an unknown name is a model id, not an error -------------------------
-- Failing a turn over a typo is worse than sending it and letting the endpoint
-- say it does not know that model.
local u = route.resolve("not-a-preset-or-anything")
eq(u.model, "not-a-preset-or-anything", "an unknown name is treated as a model id")
eq(u.url, cur.url, "on the current endpoint")

-- ---- the cheap seat -------------------------------------------------------
local util = route.utility()
eq(util.model, "qwen3.8-4b", "route.utility() finds the `cheap` preset")
eq(util.wire, "openai", "with its wire")

-- with no cheap/fast preset it must fall back rather than fail
presets.save{ ds4 = { url = "http://127.0.0.1:8000", wire = "anthropic", model = "deepseek-v4" } }
local fallback = route.utility()
eq(fallback.name, "current", "with no cheap preset, utility() is the current route")

-- ---- listing and describing ----------------------------------------------
presets.save{
  ds4 = { url = "http://127.0.0.1:8000", wire = "anthropic", model = "deepseek-v4" },
  cheap = { url = "http://127.0.0.1:8080", wire = "openai", model = "qwen3.8-4b" },
}
local list = route.list()
eq(#list, 2, "list() returns every named destination")
ok(list[1].name == "cheap" and list[2].name == "ds4", "sorted by name")
ok(route.describe(p):find("deepseek%-v4"), "describe names the model")
ok(route.describe(p):find("127%.0%.0%.1"), "and where it is going")

-- ---- per-agent: a spawned child carries its own destination --------------
local thread = require "thread"
local child = thread.new_agent{ task = "review", model = "ds4" }
eq(child.session.model, "deepseek-v4", "a child spawned with a preset gets its model")
eq(child.session.route.url, "http://127.0.0.1:8000", "and its endpoint")
eq(child.session.route.wire, "anthropic", "and its wire")

local other = thread.new_agent{ task = "write", model = "cheap" }
eq(other.session.model, "qwen3.8-4b", "a sibling can be somewhere else entirely")
ok(other.session.route.url ~= child.session.route.url,
   "two live agents hold two different destinations at once")

-- an agent spawned with nothing inherits rather than inventing
local plain = thread.new_agent{ task = "inherit" }
ok(plain.session.model ~= nil, "a child with no model spec still has one")

io.write(string.format("route: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
