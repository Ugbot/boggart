-- tests/ctxgraph_backend.lua -- the graph-memory port's contract, for any backend.
--
-- Runs every port operation (lua/ctxgraph/backend.lua) against a backend and
-- checks what the core relies on. It runs here against the SQLite backend and
-- an in-memory fake (tests/ctxgraph_fakebackend.lua), which is what shows the
-- port is not SQLite-shaped. An extension's backend reuses it unchanged:
--
--   BOGGART_GRAPH_CONTRACT=<name> boggart --eval tests/ctxgraph_backend.lua
--
-- loads the backend registered (or loadable) under <name> and checks only it.
-- Run: boggart --eval tests/ctxgraph_backend.lua
bog.store.open()
local port = require("ctxgraph.backend")
local ex = require("ctxgraph.extract")
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

local function rec(id, typ, title, seq, extra)
  local r = { id = id, type = typ, title = title, stub = title .. " stub", seq = seq, tokens = 1,
              frontmatter = { n = seq, flag = true, label = "x" }, links = {} }
  for k, v in pairs(extra or {}) do r[k] = v end
  r.digest = r.digest or ex.sha(id)
  return r
end
local function ids(rs)
  local out = {}
  for i, r in ipairs(rs) do out[i] = r.id end
  return table.concat(out, ",")
end

local function contract(be, label)
  local function L(m) return label .. ": " .. m end
  ck(port.check(be), L("implements every operation"))
  local sid, other = "c-" .. label, "c-" .. label .. "-other"
  -- put_nodes: one batch, links included
  ck(be.put_nodes(sid, {
    rec("s/1/step/1", "step", "first step", 1, { body = "ran pytest on the zebra module", body_ref = "/tmp/x", raw = "[]" }),
    rec("s/1/step/2", "step", "second step", 2, { body = "edited the parser" }),
    rec("file/a.py", "file", "a.py", 3),
    rec("file/a.py@v1", "version", "a.py v1", 4, { links = { { type = "version_of", dst = "file/a.py" } } }),
    rec("file/a.py@v2", "version", "a.py v2", 5, { links = { { type = "version_of", dst = "file/a.py" } } }),
    rec("s/1/span/1", "span", "a span", 6, { links = { { type = "contains", dst = "s/1/step/1" },
                                                       { type = "contains", dst = "s/1/step/2" } } }),
  }), L("put_nodes"))
  ck(be.put_edges(sid, { { src = "s/1/step/1", type = "reads", dst = "file/a.py" },
                         { src = "s/1/step/2", type = "edits", dst = "file/a.py" },
                         { src = "s/1/step/2", type = "edits", dst = "file/a.py" } }), L("put_edges"))
  -- get: every LOKF field round-trips
  local r = be.get(sid, "s/1/step/1")
  ck(r and port.valid_record(r), L("get returns a valid record"))
  eq(r and r.body, "ran pytest on the zebra module", L("body round-trips"))
  eq(r and r.body_ref, "/tmp/x", L("body_ref round-trips"))
  eq(r and r.raw, "[]", L("raw round-trips"))
  eq(r and r.frontmatter.n, 1, L("a number in frontmatter round-trips"))
  eq(r and r.frontmatter.flag, true, L("a boolean in frontmatter round-trips"))
  eq(r and r.digest, ex.sha("s/1/step/1"), L("digest round-trips"))
  eq(r and r.stub, "first step stub", L("stub round-trips"))
  eq(#be.get(sid, "s/1/span/1").links, 2, L("two contains links"))
  eq(be.get(sid, "missing"), nil, L("get of an unknown id is nil"))
  -- graph walks, in seq order
  eq(ids(be.children(sid, "s/1/span/1", "contains")), "s/1/step/1,s/1/step/2", L("children by edge type"))
  eq(ids(be.children(sid, "s/1/span/1")), "s/1/step/1,s/1/step/2", L("children, any edge type"))
  eq(ids(be.referrers(sid, "file/a.py")), "s/1/step/1,s/1/step/2,file/a.py@v1,file/a.py@v2", L("referrers, deduplicated"))
  eq(ids(be.referrers(sid, "file/a.py", "edits")), "s/1/step/2", L("referrers by edge type"))
  eq(ids(be.versions(sid, "file/a.py")), "file/a.py@v1,file/a.py@v2", L("versions oldest first"))
  eq(ids(be.scan(sid, { "step" })), "s/1/step/1,s/1/step/2", L("scan by type"))
  eq(#be.scan(sid), 6, L("scan everything"))
  -- replace in place
  be.put_nodes(sid, { rec("file/a.py", "file", "a.py", 3, { stub = "a.py v2" }) })
  eq(be.get(sid, "file/a.py").stub, "a.py v2", L("an entity is replaced in place"))
  eq(#be.scan(sid, { "file" }), 1, L("...not duplicated"))
  -- search: returns stubs with ids, honours limit and types
  local hits = be.search(sid, "zebra", { limit = 5 })
  eq(hits[1] and hits[1].id, "s/1/step/1", L("search finds body text"))
  ck(hits[1] and hits[1].stub == "first step stub" and hits[1].type == "step", L("a hit carries stub and type"))
  eq(#be.search(sid, "step", { limit = 1 }), 1, L("search honours limit"))
  eq(#be.search(sid, "a.py", { types = { "version" } }), 2, L("search filters by type"))
  eq(#be.search(sid, "\"NEAR( -- *", {}), 0, L("search survives query syntax"))
  -- claims: only add; state is the one mutation
  local claim = rec("claim/1", "claim", "a.py parses", 7, { state = "unverified",
    links = { { type = "about", dst = "file/a.py" } } })
  local id, created = be.record_claim(sid, claim)
  ck(id == "claim/1" and created, L("record_claim adds"))
  local _, again = be.record_claim(sid, rec("claim/1", "claim", "changed", 8, { state = "reproduced" }))
  ck(not again and be.get(sid, "claim/1").title == "a.py parses", L("record_claim never overwrites"))
  ck(be.set_claim_state(sid, "claim/1", "refuted"), L("set_claim_state"))
  eq(be.get(sid, "claim/1").state, "refuted", L("state changed"))
  ck(not be.set_claim_state(sid, "file/a.py", "refuted"), L("set_claim_state refuses a non-claim"))
  -- meta
  eq(be.meta(sid, "steps"), nil, L("meta unset is nil"))
  be.meta(sid, "steps", "41")
  eq(be.meta(sid, "steps"), "41", L("meta round-trips"))
  -- isolation: nothing crosses sessions
  eq(be.get(other, "s/1/step/1"), nil, L("get is scoped to the session"))
  eq(#be.scan(other), 0, L("scan is scoped to the session"))
  eq(#be.search(other, "zebra", {}), 0, L("search is scoped to the session"))
  eq(be.meta(other, "steps"), nil, L("meta is scoped to the session"))
  -- export
  local b = be.export_bundle(sid)
  eq(#b.records, 7, L("export_bundle has every record"))
  local bad = 0
  for _, x in ipairs(b.records) do if not port.valid_record(x) then bad = bad + 1 end end
  eq(bad, 0, L("every exported record is LOKF-shaped"))
end

local only = os.getenv("BOGGART_GRAPH_CONTRACT")
if only and only ~= "" then
  contract(assert(require("ctxgraph").get_backend(only)), only)
else
  contract(require("ctxgraph.sqlite"), "sqlite")
  contract(dofile("tests/ctxgraph_fakebackend.lua")(), "fake")
  -- registration checks the port
  local cg = require("ctxgraph")
  ck(not cg.register_backend("broken", { put_nodes = function() end }), "a backend missing operations is refused")
  ck(not cg.register_backend("local", dofile("tests/ctxgraph_fakebackend.lua")()), "a tier name cannot be a backend")
end

if fails == 0 then io.write("ok  ctxgraph_backend: the port's contract holds\n")
else io.write(string.format("FAIL ctxgraph_backend: %d check(s) failed\n", fails)); os.exit(1) end
