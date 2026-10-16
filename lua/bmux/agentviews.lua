-- Find an existing presentation of a runtime, including a worker's parent TUI.
local M={}
local function find(tree,agent,client)
  if tree.type=='leaf'then
    for _,view in ipairs(tree.views)do
      local other=view.kind=='agent'and client:find(view.agent_id)
      if view.kind=='agent'and view.agent_id==agent.id
        or other and other.terminal_id==agent.terminal_id and other.terminal_generation==agent.terminal_generation
        or view.kind=='terminal'and view.terminal_id==agent.terminal_id and view.generation==agent.terminal_generation then
        return tree.id,view.id
      end
    end
  else local pane,view=find(tree.a,agent,client);if pane then return pane,view end;return find(tree.b,agent,client)end
end
function M.find(snapshot,agent,client)
  for _,workspace in ipairs(snapshot.workspaces)do for _,surface in ipairs(workspace.surfaces)do
    local pane,view=find(surface.tree,agent,client)
    if pane then return workspace,surface,pane,view end
  end end
end
return M
