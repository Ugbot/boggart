-- tests/ctxgraph_fresh.lua -- start a ctxgraph suite from empty graphs.
--
-- The suites use fixed session ids so their expected ids ("s/701/step/3") are
-- readable, and ctest gives each suite a persistent home (build/testhome/<suite>).
-- A second run in the same build dir would find the first run's records under
-- those ids. This clears the given sessions' graphs in the local (SQLite)
-- backend and their `graph` telemetry rows (lua/ctxgraph.lua M.count), and
-- nothing else, before a suite writes anything:
--
--   dofile("tests/ctxgraph_fresh.lua")({ 701, 702 })
return function(sids)
  local sq = require("ctxgraph.sqlite")
  assert(sq.available())   -- opens the store and ensures the tables
  local c = bog.db
  for _, sid in ipairs(sids) do
    sid = tostring(sid)
    if sq.fts then
      assert(c:run("DELETE FROM ctx_fts WHERE rowid IN (SELECT rowid FROM ctx_nodes WHERE session=?)", { sid }))
    end
    for _, t in ipairs({ "ctx_nodes", "ctx_edges", "ctx_meta" }) do
      assert(c:run("DELETE FROM " .. t .. " WHERE session=?", { sid }))
    end
    assert(c:run("DELETE FROM records WHERE kind='graph' AND run_id=?", { sid }))
  end
end
