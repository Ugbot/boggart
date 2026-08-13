-- skillrouter.lua -- find the right skill for a task: FTS5/bm25 search over the
-- skill corpus (name, description, tool names, instructions).
--
-- The scoring lives in SQLite, which boggart already vendors with FTS5: the
-- router's whole job is to flatten the LIVE skill set -- embedded defaults,
-- overlay files, anything define_skill/import_skill created this session --
-- into the store's skills_fts table and ask it. The table is a derived cache,
-- rebuilt per query: the corpus is dozens of rows, so a rebuild is cheaper than
-- an invalidation protocol, and a just-imported skill missing from results is
-- exactly the kind of quiet staleness this codebase refuses elsewhere.
--
-- The router answers "which skills fit this task?" -- for the model (the
-- find_skill tool), and for anything programmatic (a coordinator choosing what
-- to hand a child it is about to spawn).
local M = {}

-- Flatten the live skill set into rows for the store. Tool names keep their
-- underscores; FTS5's unicode61 tokenizer splits on them, so a prose query
-- ("git worktree") still meets an identifier-shaped name (git_worktree).
function M.corpus()
  local skills = bog.skills
  local rows = {}
  for _, row in ipairs(skills.list()) do
    local s = skills.load(row.name)
    if s then
      local instr = s.instructions
      if type(instr) == "function" then
        local ok, res = pcall(instr)
        instr = ok and res or ""
      end
      rows[#rows + 1] = {
        name = row.name,
        description = s.description or "",
        tools = table.concat(s.tools or {}, " "),
        instructions = tostring(instr or ""),
        source = row.source,
      }
    end
  end
  return rows
end

-- route(query, n) -> { { name, score, description }, ... } best-first, or
-- nil, err when the store is not open (the one dependency this has).
function M.route(query, n)
  if not bog.db then return nil, "store unavailable" end
  local rows = M.corpus()
  bog.store.skills_reindex(rows)
  return bog.store.skills_search(query, n)
end

-- ---- the tool the model is offered -----------------------------------------

M.tools = {
  find_skill = {
    description = "Search the available skills by what you need done (FTS5 bm25 "
      .. "over names, descriptions, tool names and instructions). Returns the "
      .. "best matches with scores. Use before spawning a sub-agent, to pick the "
      .. "skills to grant it -- or to find a way of working you should follow.",
    input_schema = { type = "object",
      properties = {
        query = { type = "string", description = "what you need, in plain words" },
        n = { type = "number", description = "max results (default 5)" },
      }, required = { "query" } },
    run = function(a)
      if type(a.query) ~= "string" or a.query == "" then
        return "Tool error: [validation_error] find_skill requires 'query'"
      end
      local hits, err = M.route(a.query, tonumber(a.n) or 5)
      if not hits then return "Tool error: [host_capability_error] " .. tostring(err) end
      if #hits == 0 then
        return "no skills match; `skills` lists everything that exists"
      end
      local out = {}
      for _, h in ipairs(hits) do
        out[#out + 1] = string.format("%-18s %5.2f  %s", h.name, h.score, h.description)
      end
      return table.concat(out, "\n")
    end,
  },
}

return M
