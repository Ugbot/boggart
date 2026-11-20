-- tools/graph_export.lua -- export one conversation's graph memory as a
-- LOKF-style bundle and validate it.
--
--   boggart --eval tools/graph_export.lua -- <session-id> <out-dir> [backend]
--
-- Prints one JSON line: { session, dir, files, links, ok, errors }. Exit 1
-- when the bundle does not validate. The backend defaults to the one the
-- environment selects (BOGGART_MEMORY), else the local SQLite graph.
bog.store.open()
local args = boggart.args or {}
local sid, dir, name = args[1], args[2], args[3]
if not (sid and dir) then
  io.stderr:write("usage: boggart --eval tools/graph_export.lua -- <session-id> <out-dir> [backend]\n")
  os.exit(2)
end
local cg = require("ctxgraph")
if not name then
  local t = cg.resolve(nil)
  name = (t and t.backend) or "sqlite"
end
local be, why = cg.get_backend(name)
if not be then io.stderr:write("graph_export: ", why, "\n"); os.exit(2) end
local ex = require("ctxgraph.export")
local w = ex.write_bundle(be, tostring(sid), dir)
local ok, st = ex.validate(dir)
io.write(require("json").encode({ session = tostring(sid), dir = dir, files = w.files, links = st.links,
  ok = ok, errors = st.errors }), "\n")
if not ok then os.exit(1) end
