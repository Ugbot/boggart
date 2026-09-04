-- memory.lua -- durable, cross-session memory, backed by the SQLite store
-- (see store.lua). The system prompt gets an index of titles + previews;
-- recall uses FTS5. The remember/recall/forget tool interface is unchanged.
local M = {}

-- The project a memory operation belongs to. Everything here is scoped to the
-- CURRENT project, with `global` readable underneath and ranked below it (the
-- rule lives in store.lua's SQL). A memory written while working on one story
-- is therefore invisible to another, which is the entire point.
local function here()
  local ok, proj = pcall(require, "project")
  return ok and proj.current() or nil
end
M.scope = here

function M.list()
  local out = {}
  for _, row in ipairs(bog.store.mem_list(here())) do
    local preview = (row.body or ""):gsub("%s+", " "):sub(1, 100)
    -- A global memory surfacing inside a project is labelled, so you can see
    -- where an answer came from and demote or forget it.
    -- `is_global`, not `global`: Lua 5.5 made `global` a keyword, so it cannot
    -- be a bare key in a table constructor.
    out[#out + 1] = { title = row.title, preview = preview, body = row.body,
                      project = row.project, is_global = (row.project == nil) }
  end
  return out
end

function M.index_text()
  local items = M.list()
  if #items == 0 then
    return "(no stored memories yet -- use the remember tool to save durable facts)"
  end
  local parts = {}
  for _, it in ipairs(items) do
    parts[#parts + 1] = string.format("- %s: %s", it.title, it.preview)
  end
  return table.concat(parts, "\n")
end

-- Writes land in the current project. Promotion to global is a separate,
-- explicit act -- the opposite default would recreate exactly the bleed
-- projects exist to stop.
function M.remember(title, body) return bog.store.mem_put(title, body, here()) end

function M.recall(query)
  local rows = bog.store.mem_search(query, here())
  local parts = {}
  for _, r in ipairs(rows) do
    local head = "# " .. r.title
    if r.project == nil and not (require("project").is_global()) then
      head = head .. "   (global)"
    end
    parts[#parts + 1] = head .. "\n" .. (r.body or "")
  end
  return table.concat(parts, "\n\n---\n\n")
end

-- Forget within this project; global memories are only forgotten from global.
function M.forget(title) return bog.store.mem_del(title, here()) end

-- The explicit promotion: move a memory from this project into global, where
-- every project can read it.
function M.promote(title) return bog.store.mem_promote(title, here()) end

-- Tool definitions contributed to the registry by tools.lua.
M.tools = {
  remember = {
    description = "Save a durable fact to long-term memory (SQLite-backed) so it survives across "
      .. "sessions. Use for user preferences, project facts, decisions, and anything worth "
      .. "remembering later. Re-using a title overwrites that memory.",
    input_schema = {
      type = "object",
      properties = {
        title = { type = "string", description = "Short unique title (the key)." },
        body = { type = "string", description = "The full note to store." },
      },
      required = { "title", "body" },
    },
    run = function(a)
      if type(a.title) ~= "string" or a.title == "" then return "Tool error: remember requires a 'title'" end
      M.remember(a.title, a.body or "")
      return "Remembered: " .. a.title
    end,
  },
  recall = {
    description = "Search stored memories by full-text query (FTS5). With no query, returns all "
      .. "of them, most-recent first.",
    input_schema = {
      type = "object",
      properties = { query = { type = "string", description = "Optional full-text query." } },
    },
    run = function(a)
      local text = M.recall(a.query)
      if text == "" then return "(no matching memories)" end
      return text
    end,
  },
  forget = {
    description = "Delete a stored memory by its exact title.",
    input_schema = {
      type = "object",
      properties = { title = { type = "string" } },
      required = { "title" },
    },
    run = function(a)
      if M.forget(a.title or "") then return "Forgot: " .. tostring(a.title) end
      return "Tool error: no memory titled " .. tostring(a.title)
    end,
  },
}

return M
