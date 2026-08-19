-- workspaces.lua -- one sidebar slot; Files docks chat on the right.
--
-- Chat:  [rail | sessions | AgentView]
-- Files: [rail | tree | EmptyView-or-DocView | AgentView locked right]
-- Opening a path fills the center; the conversation stays the right dock.
local core = require "core"
local config = require "core.config"

config.chat_dock_size = 360 * SCALE

local workspaces = {}
workspaces.current = "agent"
workspaces.layout = "chat"             -- chat | files
workspaces.sidebar_mode = "sessions"
workspaces._stash = {}
workspaces._files = nil                -- docs parked while Chat is showing

local function primary()
  return core.root_view:get_primary_node()
end

local function EmptyView()
  return require("core.rootview").EmptyView()
end

local function each_content_leaf(node, t)
  if node.type == "leaf" then
    if not node.locked then t[#t + 1] = node end
  else
    each_content_leaf(node.a, t)
    each_content_leaf(node.b, t)
  end
  return t
end

local function collapse_content_leaves(root)
  while true do
    local leaves = each_content_leaf(root, {})
    if #leaves <= 1 then return end
    local merged = false
    for _, leaf in ipairs(leaves) do
      local parent = leaf:get_parent_node(root)
      if parent then
        local other = (parent.a == leaf) and parent.b or parent.a
        if not other:get_locked_size() then
          parent:consume(other)
          merged = true
          break
        end
      end
    end
    if not merged then return end
  end
end

function workspaces.tree()
  local studio = require "core.studio"
  if studio.tree then return studio.tree end
  local tree = package.loaded["plugins.treeview"]
  if type(tree) == "table" and tree.visible ~= nil then return tree end
end

function workspaces.slot_node()
  local studio = require "core.studio"
  if studio.sidebar_node then return studio.sidebar_node end
  local root = core.root_view.root_node
  if studio.sidebar then
    local n = root:get_node_for_view(studio.sidebar)
    if n then studio.sidebar_node = n; return n end
  end
  local tree = workspaces.tree()
  if tree then
    local n = root:get_node_for_view(tree)
    if n then studio.sidebar_node = n; return n end
  end
end

local function snap(view, visible)
  if not view then return end
  view.visible = visible
  view.init_size = true
  local dest = 0
  if visible and view.get_target_size then
    dest = view:get_target_size("x") or 0
  end
  view.size.x = dest
end

local function put(leaf, view)
  if not leaf or not view then return end
  leaf.views = { view }
  leaf.active_view = view
end

function workspaces.set_sidebar(mode)
  local studio = require "core.studio"
  if studio.legacy then return end
  workspaces.sidebar_mode = mode
  local slot = workspaces.slot_node()
  local tree = workspaces.tree()
  studio.tree = tree or studio.tree

  local view
  if mode == "tree" then
    view = studio.tree
    snap(studio.sidebar, false)
    snap(view, true)
  elseif mode == "sessions" then
    view = studio.sidebar
    snap(studio.tree, false)
    snap(view, true)
  else
    snap(studio.sidebar, false)
    snap(studio.tree, false)
    view = slot and slot.active_view
  end

  if slot and view and mode ~= "hidden" then
    local old = slot.active_view
    if old and old ~= view then
      view.position.x, view.position.y = old.position.x, old.position.y
      view.size.y = old.size.y
    end
    put(slot, view)
  end

  if studio.rail then
    if mode == "tree" then studio.rail.active = "edit"
    elseif mode == "sessions" then studio.rail.active = "agent"
    end
  end
  pcall(function() core.root_view.root_node:update_layout() end)
  core.redraw = true
end

local function set_stage(view)
  local node = primary()
  if not node or not view then return view end
  for _, v in ipairs(node.views) do
    if v == view then
      node:set_active_view(view)
      core.set_active_view(view)
      return view
    end
  end
  node.views = { view }
  node.active_view = view
  core.set_active_view(view)
  return view
end

local function is_empty(v)
  return v and v:is(require("core.rootview").EmptyView)
end

local function stash_current()
  local name = workspaces.current
  if not name then return end
  local root = core.root_view.root_node
  local leaves = each_content_leaf(root, {})
  local views, seen = {}, {}
  for _, leaf in ipairs(leaves) do
    for _, v in ipairs(leaf.views) do
      if not seen[v] and not is_empty(v) then
        seen[v] = true
        views[#views + 1] = v
      end
    end
  end
  local node = primary()
  local active = core.active_view
  if not active or not seen[active] then active = node and node.active_view end
  if not active or not seen[active] then active = views[#views] end
  workspaces._stash[name] = { views = views, active = active }
  if #leaves > 1 then collapse_content_leaves(root) end
end

local function restore(name)
  local node = primary()
  if not node then return end
  node.views = {}
  local st = workspaces._stash[name]
  if st and #st.views > 0 then
    for _, v in ipairs(st.views) do node.views[#node.views + 1] = v end
    node.active_view = st.active or node.views[#node.views]
  else
    node.views = { EmptyView() }
    node.active_view = node.views[1]
  end
  if node.active_view then core.set_active_view(node.active_view) end
end

function workspaces.present(name)
  local studio = require "core.studio"
  if name == "agent" then
    if studio.view then set_stage(studio.view) end
  elseif name == "fleet" then
    local SwarmView = require "core.swarmview"
    if not studio.swarm then studio.swarm = SwarmView() end
    set_stage(studio.swarm)
  elseif name == "library" then
    if not studio.library then studio.library = require("core.libraryview")() end
    set_stage(studio.library)
  elseif name == "settings" then
    if not studio.settings then studio.settings = require("core.settingsview")() end
    set_stage(studio.settings)
  elseif name == "workflows" then
    if not studio.workflows then studio.workflows = require("core.workflowview")() end
    studio.workflows:refresh()
    set_stage(studio.workflows)
  elseif name == "welcome" then
    local WelcomeView = require "core.welcomeview"
    if not WelcomeView.instance then WelcomeView.instance = WelcomeView() end
    set_stage(WelcomeView.instance)
  end
end

-- Collect DocViews from the primary leaf; leave AgentView out.
local function take_docs(leaf)
  if not leaf then return {}, nil end
  local docs, active = {}, nil
  for _, v in ipairs(leaf.views or {}) do
    if v.doc then
      docs[#docs + 1] = v
      if v == leaf.active_view then active = v end
    end
  end
  return docs, active
end

function workspaces.ensure_chat_dock()
  local studio = require "core.studio"
  if studio.chat_dock_node then return studio.chat_dock_node end
  local leaf = primary()
  if not leaf then return nil end
  leaf:split("right", EmptyView(), true)
  studio.chat_dock_node = leaf.b
  return studio.chat_dock_node
end

function workspaces.hide_chat_dock()
  local studio = require "core.studio"
  local dock = studio.chat_dock_node
  local agent = studio.view
  if agent then
    agent.docked = false
    agent.visible = true
    agent.init_size = true
  end
  if not dock then return end
  local root = core.root_view.root_node
  local parent = dock:get_parent_node(root)
  local prim = primary()
  if agent and prim then
    local docs = {}
    for _, v in ipairs(prim.views or {}) do
      if v ~= agent and not is_empty(v) then docs[#docs + 1] = v end
    end
    if #docs > 0 then
      workspaces._files = { views = docs, active = prim.active_view }
    end
    put(prim, agent)
    core.set_active_view(agent)
  end
  if parent and parent.b == dock then
    parent:consume(parent.a)
  elseif parent and parent.a == dock then
    parent:consume(parent.b)
  end
  studio.chat_dock_node = nil
end

function workspaces.layout_files()
  local studio = require "core.studio"
  local agent = studio.view
  if not agent then return end
  local prim = primary()
  if not prim then return end

  local docs, active = take_docs(prim)
  if workspaces._files and #(workspaces._files.views or {}) > 0 then
    docs = workspaces._files.views
    active = workspaces._files.active or docs[1]
  end

  local dock = workspaces.ensure_chat_dock()
  prim = primary()
  agent.docked = true
  agent.visible = true
  snap(agent, true)
  if dock then put(dock, agent) end

  if #docs == 0 then
    put(prim, EmptyView())
  else
    prim.views = docs
    prim.active_view = active or docs[1]
  end
  workspaces._files = nil
  workspaces.layout = "files"
  workspaces.set_sidebar("tree")
end

function workspaces.layout_chat()
  workspaces.hide_chat_dock()
  workspaces.layout = "chat"
  workspaces.set_sidebar("sessions")
end

local function go_stage(name)
  local studio = require "core.studio"
  if name == workspaces.current then
    if name ~= "agent" then workspaces.present(name) end
    return
  end
  if workspaces.layout == "files" then workspaces.hide_chat_dock() end
  stash_current()
  restore(name)
  workspaces.current = name
  if studio then studio.workspace = name end
  local node = primary()
  local empty = node and node.active_view and is_empty(node.active_view)
  if empty or name ~= "agent" then
    workspaces.present(name)
  end
end

function workspaces.show_chat()
  if workspaces.current ~= "agent" then go_stage("agent") end
  workspaces.layout_chat()
end

function workspaces.show_files()
  if workspaces.current ~= "agent" then go_stage("agent") end
  workspaces.layout_files()
end

function workspaces.switch(name)
  if not name then return end
  if name == "edit" or name == "files" then
    workspaces.show_files()
    return
  end
  if name == "agent" then
    workspaces.show_chat()
    return
  end
  go_stage(name)
  workspaces.layout = "chat"
  workspaces.set_sidebar("hidden")
  local studio = require "core.studio"
  if studio.rail then studio.rail.active = name end
  pcall(function() core.root_view.root_node:update_layout() end)
  core.redraw = true
end

function workspaces.apply_docks(name)
  if name == "edit" or name == "files" then
    workspaces.set_sidebar("tree")
  elseif name == "agent" then
    workspaces.set_sidebar("sessions")
  else
    workspaces.set_sidebar("hidden")
  end
end

function workspaces.open_doc(doc)
  local studio = require "core.studio"
  if workspaces.layout ~= "files" then
    workspaces.show_files()
  end
  local DocView = require "core.docview"
  local leaf = primary()
  if not leaf then return end
  for _, v in ipairs(leaf.views) do
    if v.doc == doc then
      leaf:set_active_view(v)
      core.set_active_view(v)
      return v
    end
  end
  local view = DocView(doc)
  if #leaf.views == 1 and is_empty(leaf.views[1]) then
    put(leaf, view)
  else
    leaf:add_view(view)
  end
  core.set_active_view(view)
  pcall(function() core.root_view.root_node:update_layout() end)
  core.redraw = true
  return view
end

function workspaces.install_open_hook()
  if workspaces._hooked then return end
  workspaces._hooked = true
  local RootView = require "core.rootview"
  local orig = RootView.open_doc
  function RootView:open_doc(doc)
    local studio = require "core.studio"
    if studio.legacy then return orig(self, doc) end
    return workspaces.open_doc(doc)
  end
end

return workspaces
