-- Authoritative session hierarchy; terminals and execution adapters own processes.
local Tree = require 'bmux.tree'
local json = require 'json'
local M = {}
local Host = {}; Host.__index = Host
local defaults = {workspaces=16, surfaces=64, panes=256, views=512, tabs=32, depth=24}

local function failure(status, message) return nil, {status=status, message=message} end
local function array(values) return #values > 0 and values or json.array end
local function canonical(surface) return surface.tree.zoomed or surface.tree end
local function find(items, id)
  for i, item in ipairs(items) do if item.id == id then return item, i end end
end
local function tree_stats(node)
  if node.type == 'leaf' then
    local count = 0
    for _, view in ipairs(node.views) do if not view.empty then count = count + 1 end end
    return 1, count
  end
  local p1, v1 = tree_stats(node.a)
  local p2, v2 = tree_stats(node.b)
  return p1 + p2, v1 + v2
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.resolve) == 'function', 'layout reference resolver required')
  assert(opts.host_id==nil or type(opts.host_id)=='string' and #opts.host_id<=128
    and opts.host_id:match('^[%w_-]+$'), 'invalid layout host identity')
  assert(opts.limits==nil or type(opts.limits)=='table', 'invalid layout limits')
  for key in pairs(opts.limits or {}) do assert(defaults[key], 'unknown layout limit') end
  local limits = {}
  for key, maximum in pairs(defaults) do
    local n = opts.limits and opts.limits[key]
    if n==nil then n=maximum end
    assert(type(n) == 'number' and n % 1 == 0 and n >= 1 and n <= maximum, 'invalid layout limit')
    limits[key] = n
  end
  local self = setmetatable({host_id=opts.host_id or serve.token(16), revision=0,
    serial=0, workspaces={}, resolve=opts.resolve, limits=limits}, Host)
  self.Node = Tree.class {
    empty=function() return {empty=true} end,
    is_empty=function(view) return view.empty end,
    focused=function() return self._focused end,
    focus=function(view) self._focused = view end,
  }
  return self
end

function Host:_id(kind)
  self.serial = self.serial + 1
  return kind .. '-' .. self.serial
end

function Host:_new_surface(title)
  local tree = self.Node()
  return {id=self:_id('surface'), title=title, tree=tree, focused_pane=tree.id}
end

function Host:_workspace(id) return find(self.workspaces, id) end
function Host:_surface(workspace, id) return find(workspace.surfaces, id) end
function Host:_canonical(surface) return canonical(surface) end

function Host:_stats()
  local result = {workspaces=#self.workspaces, surfaces=0, panes=0, views=0}
  for _, workspace in ipairs(self.workspaces) do
    result.surfaces = result.surfaces + #workspace.surfaces
    for _, surface in ipairs(workspace.surfaces) do
      local panes, views = tree_stats(canonical(surface))
      result.panes, result.views = result.panes + panes, result.views + views
    end
  end
  return result
end

function Host:_activate(surface)
  local node = canonical(surface):find_node(surface.focused_pane)
  self._focused = node and node.active_view
end

function Host:_finish(surface)
  local tree = canonical(surface)
  local node = tree:get_node_for_view(self._focused) or tree:find_node(surface.focused_pane)
  if not node or node.type ~= 'leaf' then node = tree:get_primary_node() end
  surface.focused_pane = node.id
end

local function view_snapshot(view)
  return {id=view.id, kind=view.kind, terminal_id=view.terminal_id,
    generation=view.generation, agent_id=view.agent_id, title=view.title}
end
local function node_snapshot(node)
  local out = {id=node.id, type=node.type}
  if node.type == 'leaf' then
    local views = {}
    for _, view in ipairs(node.views) do
      if not view.empty then views[#views+1] = view_snapshot(view) end
    end
    out.views = array(views)
    out.active_view_id = node.active_view and node.active_view.id or json.null
  else
    out.divider, out.a, out.b = node.divider, node_snapshot(node.a), node_snapshot(node.b)
  end
  return out
end

function Host:snapshot()
  local workspaces = {}
  for _, workspace in ipairs(self.workspaces) do
    local surfaces = {}
    for _, surface in ipairs(workspace.surfaces) do
      surfaces[#surfaces+1] = {id=surface.id, title=surface.title,
        focused_pane_id=surface.focused_pane,
        zoomed_pane_id=surface.tree.zoomed and surface.tree.id or json.null,
        tree=node_snapshot(canonical(surface))}
    end
    workspaces[#workspaces+1] = {id=workspace.id, title=workspace.title,
      selected_surface_id=workspace.selected_surface, surfaces=array(surfaces)}
  end
  return {v=1, host_id=self.host_id, revision=self.revision,
    selected_workspace_id=self.selected_workspace or json.null, workspaces=array(workspaces)}
end

function Host:command(command)
  local effect, why = require('bmux.layoutcommands').prepare(self, command)
  if not effect then return nil, why end
  if self.revision >= 9007199254740990 or self.serial >= 9007199254740980 then
    return failure(503, 'layout identity exhausted')
  end
  effect()
  self.revision = self.revision + 1
  return self:snapshot()
end

return M
