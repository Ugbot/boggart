-- BMUX: live native terminal tabs/splits, with discoverable mouse controls.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local TerminalView = require "core.terminalview"
local Toolbar = require "shell.bmuxtoolbar"

local M = { preserve_layout = true }

local function target_node()
  local root = core.root_view.root_node
  local node = core.root_view:get_active_node()
  if node and not node.locked then return node end
  return (M.focused and root:get_node_for_view(M.focused)) or core.root_view:get_primary_node()
end

-- Structural edits operate on the full tree. Closing/splitting a zoomed leaf
-- must not discard its saved neighbours or strand new panes inside zoom state.
local function full_layout_node()
  local node = target_node()
  node:set_active_view(node.active_view)
  local root = core.root_view.root_node
  local content = node:get_content_root(root)
  if content.zoomed then
    content:toggle_zoom()
    node = root:get_node_for_view(core.active_view)
    node:set_active_view(core.active_view)
  end
  return node
end

function M.remember_focus()
  if require('shell').current~='bmux'then return end
  local root=core.root_view.root_node;local view=core.active_view;local node=root:get_node_for_view(view)
  if node and node.locked then view=core.last_active_view;node=root:get_node_for_view(view)end
  if node and not node.locked then
    M.last_content_view=view
    if view:is(TerminalView)then M.focused=view end
  end
end

local function shell_cwd()
  local cwd = M.focused and M.focused.cwd
  if cwd then
    local path = cwd:match("^file://[^/]*(/.*)$") or cwd
    path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    if not path:find("\0", 1, true) then
      local info = system.get_file_info(path)
      if info and info.type == "dir" then return path end
    end
  end
  return (M.focused and M.focused.bmux_cwd) or core.project_dir
end

function M.open(dir, options)
  options = options or nil
  if M.session then
    if options and options.fleet_agent then M.session:disconnect()
    else return M.session:open_terminal(dir,options)end
  end
  local shell = require "shell"
  if shell.current ~= "bmux" then
    M.suppress_initial=options and options.attachment~=nil
    local ok,why=pcall(shell.switch,"bmux");M.suppress_initial=nil
    if not ok then error(why,0)end
    -- First entry creates the initial shell; a menu open should not spawn two.
    if not dir and not options then return end
  end
  local node = full_layout_node()
  local cwd = (options and options.cwd) or shell_cwd()
  local view = TerminalView { cwd=cwd, cmd=options and options.cmd,
    args=options and options.args, title=options and options.title, control=options and options.control,
    fleet_agent=options and options.fleet_agent,attachment=options and options.attachment,bmux_context=true }
  M.serial = (M.serial or 0) + 1
  view.title = (options and options.title) or ("Terminal " .. M.serial)
  view.bmux_cwd = cwd
  if dir then node:split(dir, view) else node:add_view(view) end
  M.focused = view
  core.root_view.root_node:update_layout()
  core.redraw = true
  return view
end

function M.show(view)
  if M.session and M.session.local_tree and M.session.local_tree:get_node_for_view(view)then M.session:disconnect()end
  require("shell").switch("bmux")
  local root = core.root_view.root_node
  local node = root:get_node_for_view(view)
  if not node then
    local content = core.root_view:get_primary_node():get_content_root(root)
    if content.zoomed then content:toggle_zoom(); node = root:get_node_for_view(view) end
  end
  if not node then return nil, "agent pane is closed" end
  node:set_active_view(view); M.focused=view; core.redraw=true
  return true
end

function M.enter()
  require("shell").set_docks("bmux")
  if not M.toolbar then
    M.toolbar = Toolbar(M)
    core.root_view:get_primary_node():split("up", M.toolbar, true)
  end
  M.toolbar.visible = true
  if M.session then M.session:apply();return end
  local root = core.root_view.root_node
  if not (core.active_view and core.active_view:is(TerminalView) and root:get_node_for_view(core.active_view)) then
    local node = M.focused and root:get_node_for_view(M.focused)
    if node then node:set_active_view(M.focused)
    else
      for _, leaf in ipairs(root:get_leaves()) do
        for _, view in ipairs(leaf.views) do
          if view:is(TerminalView) then leaf:set_active_view(view); M.focused = view; return end
        end
      end
      if not M.suppress_initial then M.open()end
    end
  end
  M.remember_focus()
end

function M.leave()
  if M.toolbar then M.toolbar.visible = false end
  require("shell").set_docks(nil)
end

local function in_bmux() return require("shell").current == "bmux" end
command.add(in_bmux, {
  ["bmux:new-agent"] = function()
    if M.session then M.session.agents:choose()else require('core.agentlauncher').choose()end
  end,
  ["bmux:new-local-agent"] = function()require('core.agentlauncher').choose()end,
  ["bmux:new-terminal"] = function() M.open() end,
  ["bmux:split-right"] = function() M.open("right") end,
  ["bmux:split-down"] = function() M.open("down") end,
  ["bmux:close-terminal"] = function()
    if M.session then target_node():close_active_view(core.root_view.root_node);return end
    local node = full_layout_node()
    node:close_active_view(core.root_view.root_node)
    M.focused = core.active_view
  end,
  ["bmux:zoom"] = function()
    if M.session then M.session:command('pane_zoom',{pane_id=M.session:focused_pane()});return end
    local node = target_node(); node:set_active_view(node.active_view)
    node:get_content_root(core.root_view.root_node):toggle_zoom()
    core.redraw = true
  end,
  ["bmux:next-pane"] = function()
    if M.session then M.session:cycle(1);return end
    local node = target_node(); node:set_active_view(node.active_view)
    command.perform("root:next-pane"); M.remember_focus()
  end,
})
keymap.add {
  ["cmd+t"] = "bmux:new-terminal",
  ["cmd+d"] = "bmux:split-right",
  ["cmd+shift+d"] = "bmux:split-down",
  ["cmd+w"] = "bmux:close-terminal",
  ["ctrl+alt+t"] = "bmux:new-terminal",
  ["ctrl+alt+d"] = "bmux:split-right",
  ["ctrl+alt+shift+d"] = "bmux:split-down",
}

return M
