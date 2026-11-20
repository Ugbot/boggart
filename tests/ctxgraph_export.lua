-- tests/ctxgraph_export.lua -- a conversation's graph as a LOKF-style bundle.
--
-- Ingests the 40-step fixture, adds a model note, exports one Markdown file
-- per record and validates the bundle: every file parses, carries id / type /
-- title / digest (and a state for claims), its name matches its id, and every
-- link resolves to a record in the bundle. A damaged bundle must fail.
-- Run: boggart --eval tests/ctxgraph_export.lua
bog.store.open()
dofile("tests/ctxgraph_fresh.lua")({ 501 })
local util = require("util")
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

local msgs = dofile("tests/ctxgraph_fixture.lua")()
msgs[#msgs + 1] = { role = "assistant", content = { { type = "text", text = "done" } } }
local sess = { id = 501, model = "mock", memory = "local", messages = msgs, context_limit = 8000, compact_ratio = 0.01 }
bog.session = sess
ck(bog.api.compact(sess, { stream = function() error("no model call") end, system = function() return "" end }), "compacted")
bog.tools.run("note", { text = "tests need PYTHONPATH=src", about = "src/parser.py" })

local ex = require("ctxgraph.export")
local be = require("ctxgraph").backend(sess)
local dir = bog.userdir .. "/bundle-501"
local w = ex.write_bundle(be, "501", dir)
eq(w.files, #be.scan("501"), "one file per record")
local ok, st = ex.validate(dir)
for _, e in ipairs(st.errors) do io.write("    ", e, "\n") end
ck(ok, "the bundle validates")
ck(st.links > 100, "links were checked (" .. st.links .. ")")

-- a file reads back as the record it came from
local p = assert(ex.parse(util.read_file(dir .. "/" .. ex.filename("file/src/parser.py"))))
eq(p.fm.id, "file/src/parser.py", "frontmatter id")
eq(p.fm.type, "file", "frontmatter type")
eq(p.fields.versions, 4, "record fields")
local claim
for _, r in ipairs(be.scan("501", { "claim" })) do if r.state == "unverified" then claim = r end end
p = assert(ex.parse(util.read_file(dir .. "/" .. ex.filename(claim.id))))
eq(p.fm.state, "unverified", "a claim carries its state")
eq(p.links.about and p.links.about[1], "file/src/parser.py", "typed links by edge type")
p = assert(ex.parse(util.read_file(dir .. "/" .. ex.filename("s/501/span/1"))))
ck(p.links.contains and #p.links.contains == 3, "a span links its steps")

-- the validator catches a dangling link
util.write_file(dir .. "/" .. ex.filename("s/501/step/1"),
  "---\nid: \"s/501/step/1\"\ntype: \"step\"\ntitle: \"x\"\ndigest: \"d\"\nlinks:\n  next:\n    - \"s/501/step/999\"\n---\nbody\n")
ok, st = ex.validate(dir)
ck(not ok and st.errors[1] and st.errors[1]:find("does not resolve", 1, true), "a dangling link fails validation")

-- the command-line helper
local out = sys.exec(string.format("BOGGART_HOME=%q %q --eval tools/graph_export.lua -- 501 %q 2>&1",
  bog.userdir, (os.getenv("BOGGART_TEST_BIN") or "./boggart"), bog.userdir .. "/bundle-cli"), 60)
ck(out.code == 0 and out.out:find('"ok":true', 1, true), "tools/graph_export.lua exports and validates: " .. out.out:sub(-200))

if fails == 0 then io.write("ok  ctxgraph_export: the graph exports as a valid LOKF-style bundle\n")
else io.write(string.format("FAIL ctxgraph_export: %d check(s) failed\n", fails)); os.exit(1) end
