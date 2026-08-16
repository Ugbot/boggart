-- shell/workspaces/fleet.lua -- the FLEET workspace: the swarm. P2 shows the
-- existing SwarmView (roster + claims + journal); P4 gives it its own docks and
-- adds the sub-agent approval gate.
local core = require "core"

local M = {}

function M.enter()
  local ok, SwarmView = pcall(require, "core.swarmview")
  if not ok then return end
  local shell = require "shell"
  shell.fleet = shell.fleet or SwarmView()
  local node = core.root_view:get_primary_node()
  local found = false
  for _, v in ipairs(node.views) do if v == shell.fleet then found = true; break end end
  if not found then node:add_view(shell.fleet) end
  node:set_active_view(shell.fleet)
  core.set_active_view(shell.fleet)
end

function M.leave() end

return M
