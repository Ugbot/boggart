-- claims.lua -- a shared "blackboard" of which agent is editing which file, so
-- concurrent agents coordinate instead of colliding. In a swarm the actors are
-- coroutines sharing this one process, so this in-memory registry is genuinely
-- shared between them; a coordinator hands out work, and agents claim the files
-- they touch.
--
-- It is ADVISORY: a claim warns and coordinates, it does not physically lock a
-- file. The strong isolation is a git worktree per agent (see
-- docs/git-integration.md) -- separate working directories cannot collide at
-- all. Claims are for the cases worktrees do not cover: agents deliberately
-- sharing one tree, and non-git files (a folder of documents) where there are no
-- worktrees to hand out. Where the per-agent blackboard (lua/blackboard.lua)
-- holds one agent's private beliefs, this holds the shared truth all agents read.
local M = {}

M.LIMITS = { claims = 4096 }

-- path -> { writer = agent|nil, readers = { [agent] = true, ... } }
local reg = {}

function M.current()
  return (bog and bog.current_agent)
    or (bog and bog.session and bog.session.id)
    or "main"
end

-- Light normalisation so "./a" and "a" are the same claim. Not a realpath (sys
-- is not always present); enough to stop the obvious ways two agents miss each
-- other on the same file.
local function norm(path)
  path = tostring(path or "")
  path = path:gsub("/+", "/"):gsub("^%./", "")
  while true do
    local n
    path, n = path:gsub("/%./", "/")
    if n == 0 then break end
  end
  return path
end

local function entry(path)
  local e = reg[path]
  if not e then
    local n = 0
    for _ in pairs(reg) do n = n + 1 end
    assert(n < M.LIMITS.claims, "claim table budget exhausted")
    e = { writer = nil, readers = {} }
    reg[path] = e
  end
  return e
end

local function other_readers(e, agent)
  for a in pairs(e.readers) do if a ~= agent then return a end end
  return nil
end

-- claim(path, mode, agent) -> true | nil, holder_description
-- mode "write" is exclusive; "read" is shared with other readers but not a writer.
function M.claim(path, mode, agent)
  path = norm(path)
  agent = agent or M.current()
  mode = mode or "write"
  local e = entry(path)

  if mode == "write" then
    if e.writer and e.writer ~= agent then
      return nil, "held for write by " .. e.writer
    end
    local r = other_readers(e, agent)
    if r then return nil, "held for read by " .. r end
    e.writer = agent
    e.readers[agent] = nil
    return true
  else -- read
    if e.writer and e.writer ~= agent then
      return nil, "held for write by " .. e.writer
    end
    e.readers[agent] = true
    return true
  end
end

function M.release(path, agent)
  path = norm(path)
  agent = agent or M.current()
  local e = reg[path]
  if not e then return end
  if e.writer == agent then e.writer = nil end
  e.readers[agent] = nil
  if not e.writer and not next(e.readers) then reg[path] = nil end
end

-- Drop everything an agent holds -- wire to swarm:actor_stopped so a dead agent
-- does not hold files hostage.
function M.release_all(agent)
  agent = agent or M.current()
  for path, e in pairs(reg) do
    if e.writer == agent then e.writer = nil end
    e.readers[agent] = nil
    if not e.writer and not next(e.readers) then reg[path] = nil end
  end
end

function M.holder(path)
  local e = reg[norm(path)]
  if not e then return nil end
  return { writer = e.writer, readers = (function()
    local rs = {}; for a in pairs(e.readers) do rs[#rs + 1] = a end; table.sort(rs); return rs
  end)() }
end

function M.list()
  local out = {}
  for path, e in pairs(reg) do
    local rs = {}
    for a in pairs(e.readers) do rs[#rs + 1] = a end
    table.sort(rs)
    out[#out + 1] = { path = path, writer = e.writer, readers = rs }
  end
  table.sort(out, function(a, b) return a.path < b.path end)
  return out
end

-- ---- the tools the model is offered ----------------------------------------

M.tools = {
  claim = {
    description = "Claim a file before editing it, so other agents know it is taken "
      .. "(advisory; real isolation is a worktree). mode 'write' is exclusive, 'read' "
      .. "is shared. Fails with the current holder if someone else has it -- pick other "
      .. "work rather than colliding.",
    input_schema = { type = "object",
      properties = {
        path = { type = "string" },
        mode = { type = "string", description = "write (default) | read" },
      }, required = { "path" } },
    run = function(a)
      if type(a.path) ~= "string" then return "Tool error: [validation_error] claim requires 'path'" end
      local mode = a.mode == "read" and "read" or "write"
      local ok, held = M.claim(a.path, mode)
      if not ok then return "unavailable: " .. a.path .. " is " .. held .. " -- claim other work" end
      return string.format("claimed %s for %s", a.path, mode)
    end,
  },

  release = {
    description = "Release a file you claimed, so other agents can take it.",
    input_schema = { type = "object",
      properties = { path = { type = "string" } }, required = { "path" } },
    run = function(a)
      if type(a.path) ~= "string" then return "Tool error: [validation_error] release requires 'path'" end
      M.release(a.path)
      return "released " .. a.path
    end,
  },

  claims = {
    description = "Show which agent is editing which file (the shared edit blackboard).",
    input_schema = { type = "object", properties = {} },
    run = function()
      local rows = M.list()
      if #rows == 0 then return "(no files claimed)" end
      local out = {}
      for _, r in ipairs(rows) do
        local who = r.writer and ("write:" .. r.writer) or ""
        if #r.readers > 0 then
          who = who .. (who ~= "" and "  " or "") .. "read:" .. table.concat(r.readers, ",")
        end
        out[#out + 1] = string.format("%-40s %s", r.path, who)
      end
      return table.concat(out, "\n")
    end,
  },
}

return M
