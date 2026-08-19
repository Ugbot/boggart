-- agents.lua -- standard agent specs. A spec is { system?, model?, skills={} }.
-- Standard agents live under lua/agents/<name>.lua (embedded defaults,
-- overlay-able under ~/.boggart/lua/agents/). Spawn one by name.
local M = {}

function M.load(name)
  local ok, mod = pcall(require, "agents." .. name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

function M.list()
  -- known embedded standard agents (overlay may add more, not enumerated here)
  return { "coordinator", "planner", "researcher", "coder", "critic" }
end

return M
