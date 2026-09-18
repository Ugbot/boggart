-- terminal.lua -- registers terminal:open, the front door to TerminalView
-- (core/terminalview.lua, docs/studio-panels.md phase 3). Opens a shell in
-- a split of the active pane the same way any other view lands: through
-- RootView:open_view_in, which phase 1 already added.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local TerminalView = require "core.terminalview"

command.add(nil, {
  ["terminal:open"] = function()
    core.root_view:open_view_in("down", TerminalView())
  end,
})

-- Ctrl-` (the VS Code / common-terminal convention) opens one below the
-- active pane. Leaving it is Ctrl-Alt-<arrow>/w (panes.lua) -- see
-- TerminalView:is_text_input for why that is the escape hatch, not Ctrl-w.
keymap.add {
  ["ctrl+`"] = "terminal:open",
}
