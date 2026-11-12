-- terminal.lua -- registers terminal:open, the front door to TerminalView
-- (core/terminalview.lua, docs/studio-panels.md phase 3). Opens a shell in
-- a split of the active pane the same way any other view lands: through
-- RootView:open_view_in, which phase 1 already added.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local TerminalView = require "core.terminalview"

command.add(nil, {
  ["terminal:attach"] = function() require('core.terminalattach').choose()end,
  ['bmux:join-layout']=function()require('core.bmuxlayoutui').join()end,
  ['bmux:server-workspaces']=function()require('core.bmuxlayoutui').workspaces()end,
  ['bmux:server-surfaces']=function()require('core.bmuxlayoutui').surfaces()end,
  ['bmux:sessions']=function()require('core.bmuxsessions').show()end,
  ['bmux:refresh-layout']=function()require('core.bmuxlayoutui').refresh()end,
  ['bmux:disconnect-layout']=function()require('core.bmuxlayoutui').disconnect()end,
  ["terminal:open"] = function()
    local shell = package.loaded["shell"]
    if shell and shell.current == "bmux" then
      require("shell.workspaces.bmux").open()
      return
    end
    core.root_view:open_view_in("down", TerminalView())
  end,
})
command.add(function()
  local view=core.active_view
  return view and view:is(TerminalView) and view.remote and view
end,{
  ['terminal:take-control']=function()core.active_view.remote:control(false)end,
  ['terminal:take-over']=function()core.active_view.remote:control(true)end,
  ['terminal:view-only']=function()core.active_view.remote:view_only()end,
  ['terminal:reconnect']=function()core.active_view.remote:reconnect()end,
  ['terminal:retry-pending-command']=function()core.active_view.remote:retry()end,
})

-- Ctrl-` (the VS Code / common-terminal convention) opens one below the
-- active pane. Leaving it is Ctrl-Alt-<arrow>/w (panes.lua) -- see
-- TerminalView:is_text_input for why that is the escape hatch, not Ctrl-w.
keymap.add {
  ["ctrl+`"] = "terminal:open",
  ["ctrl+alt+a"] = "terminal:attach",
  ["ctrl+alt+c"] = "terminal:take-control",
  ["ctrl+alt+r"] = "terminal:reconnect",
}
