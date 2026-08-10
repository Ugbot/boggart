-- memory.lua -- durable, cross-session memory, backed by the SQLite store
-- (see store.lua). The system prompt gets an index of titles + previews;
-- recall uses FTS5. The remember/recall/forget tool interface is unchanged.
local M = {}

function M.list()
  local out = {}
  for _, row in ipairs(bog.store.mem_list()) do
    local preview = (row.body or ""):gsub("%s+", " "):sub(1, 100)
    out[#out + 1] = { title = row.title, preview = preview, body = row.body }
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

function M.remember(title, body) return bog.store.mem_put(title, body) end

function M.recall(query)
  local rows = bog.store.mem_search(query)
  local parts = {}
  for _, r in ipairs(rows) do
    parts[#parts + 1] = "# " .. r.title .. "\n" .. (r.body or "")
  end
  return table.concat(parts, "\n\n---\n\n")
end

function M.forget(title) return bog.store.mem_del(title) end

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
