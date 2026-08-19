-- shell/workspaces/agent.lua -- the AGENT workspace: the conversation plus the
-- recents rail (legacy SidebarView, Chat/Code stripped). Sessions are also in
-- the Agent menu; the rail is the same list you can click without a picker.
local core = require "core"

local M = {}

function M.enter()
  require("shell").set_docks("agent")
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

function M.leave()
  require("shell").set_docks(nil)
end

return M
