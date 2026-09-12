-- skill: gestalt -- answer a deep data question over the Gestalt data plane
-- (SQL / graph / lineage), computed not guessed. See lua/gestalt.lua.
--
-- The compile (docs/compounding.md): schema discovery is the deterministic
-- slice, so `before` pulls the table catalog as CODE and threads it into the
-- turn. The model never spends a round-trip finding out what tables exist; it
-- starts already knowing them, and its only job is question -> query -> read.
-- When no daemon answers, `before` short-circuits so the skill degrades to
-- "no Gestalt here" instead of the model inventing an answer.
return {
  description = "Answer a data question by querying Gestalt (SQL over tables, "
    .. "SPARQL/Cypher over the graph, or lineage). Use for questions whose "
    .. "answer should be computed from stored data, not estimated.",
  invocation = "model",
  fallback = { "core" },
  tools = {
    "gestalt_schema", "gestalt_query", "gestalt_graph", "gestalt_lineage",
  },

  before = function()
    if not (bog.gestalt and bog.gestalt.available()) then
      return { done = "no Gestalt data plane reachable (set GESTALT_URL or "
        .. "start gestaltd); answer from another source or say so." }
    end
    local data = bog.gestalt.tables()
    local names = {}
    for _, t in ipairs((data and data.tables) or {}) do
      local cols = {}
      for _, c in ipairs(t.columns or {}) do cols[#cols + 1] = c.name end
      names[#names + 1] = t.name .. "(" .. table.concat(cols, ", ") .. ")"
    end
    return { set = { schema = names } }
  end,

  instructions = function(ctx)
    local schema = (ctx and ctx.schema) or {}
    local body = #schema > 0
      and ("Tables (already discovered in code):\n  " .. table.concat(schema, "\n  "))
      or ("The table catalog was empty or unavailable; call `gestalt_schema` "
          .. "yourself, or use `gestalt_graph` for graph questions.")
    return [[
# Answer a data question with Gestalt

]] .. body .. [[


1. Translate the question into ONE query against the tables above:
   `gestalt_query` for SQL, `gestalt_graph` (lang=sparql|cypher) for the graph,
   `gestalt_lineage` for provenance. Name only columns that appear above.
2. Run it. If it errors, read the error and fix the query; do not guess a result.
3. Report the answer grounded in the rows returned. Every number you state must
   come from a query result, never an estimate. Show the query you ran.
]]
  end,

  -- No `verify` field: grounding a data answer is a check over the turn's own
  -- content, not an arg-free code check, and a bare prose string would be read
  -- as a tool name (lua/skills.lua:158). The grounding rule lives in step 3.
}
