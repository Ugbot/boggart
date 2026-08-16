-- shell/workspaces/agent.lua -- the AGENT workspace: the conversation. Kept
-- deliberately clean -- just the AgentView in the primary node. Sessions are
-- reached from the Agent menu (New session / Resume session); Settings and
-- Library open as utility tabs. (The old SidebarView with its Chat/Code control
-- and "the tree is on the right" text is NOT reused here -- that faking is what
-- the shell replaces.)
local core = require "core"

local M = {}

function M.enter()
  local studio = package.loaded["core.studio"]
  local view = studio and studio.view
  if not view then return end
  local node = core.root_view:get_primary_node()
  local found = false
  for _, v in ipairs(node.views) do if v == view then found = true; break end end
  if not found then node:add_view(view) end
  node:set_active_view(view)
  core.set_active_view(view)
end

function M.leave() end

return M
