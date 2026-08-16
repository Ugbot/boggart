-- shell/workspaces/edit.lua -- the EDIT workspace: file tree (left) + the editor
-- (buffers) in the centre. With per-workspace content isolation (shell.switch),
-- this leaf holds ONLY editor buffers -- no conversation tab -- so it reads as a
-- real code editor. Open files from the tree or Ctrl-P.
local core = require "core"
local DocView = require "core.docview"

local M = {}

local function tree()
  local ok, v = pcall(require, "plugins.treeview")
  return ok and v or nil
end

function M.enter()
  local t = tree(); if t then t.visible = true end
  -- activate a buffer if one is open; otherwise the leaf shows the splash and
  -- you open a file from the tree or Ctrl-P.
  local node = core.root_view:get_primary_node()
  local doc
  for _, v in ipairs(node.views) do
    if getmetatable(v) == DocView then doc = v end
  end
  if doc then
    node:set_active_view(doc)
    core.set_active_view(doc)
  end
end

function M.leave()
  local t = tree(); if t then t.visible = false end
end

return M
