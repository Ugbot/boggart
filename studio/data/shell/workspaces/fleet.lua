-- shell/workspaces/fleet.lua -- the FLEET workspace: the swarm roster.
-- Uses SwarmView.ensure() so this workspace and `agent:swarm` / `swarm:open`
-- are one view on one scheduler, not two rosters over the same fleet.
local core = require "core"

local M = {}

function M.enter()
  local ok, SwarmView = pcall(require, "core.swarmview")
  if not ok then return end
  local view = SwarmView.ensure()
  local node = core.root_view:get_primary_node()
  local found = false
  for _, v in ipairs(node.views) do if v == view then found = true; break end end
  if not found then node:add_view(view) end
  node:set_active_view(view)
  core.set_active_view(view)
end

function M.leave() end

return M
