-- shell/registry.lua -- the grouped command registry: the ONE source that drives
-- the menu bar, the grouped choosers (menus + which-key), and key hints. Each
-- menu is an ordered list of { title, command } rows (or the SEP marker). The
-- commands themselves are the existing core/agent/root verbs -- this layer only
-- gives them structure, names, and a home.
local keymap = require "core.keymap"

local M = {}
M.SEP = { sep = true }

M.tree = {
  boggart = {
    { "Command palette\u{2026}", "core:find-command" },
    M.SEP,
    { "Welcome (set up a model)", "agent:welcome" },
    { "Settings\u{2026}",        "agent:settings" },
    { "Font\u{2026}",            "studio:set-font" },
    { "Font size\u{2026}",       "studio:font-size" },
    { "Reset fonts",         "studio:reset-fonts" },
    { "Reload harness",         "core:reload-module" },
    M.SEP,
    { "Quit",                   "core:quit" },
  },
  File = {
    { "New file",       "core:new-doc" },
    { "Open file\u{2026}",   "core:open-file" },
    { "Find file\u{2026}",   "core:find-file" },
    { "Open folder\u{2026}", "studio:open-folder" },
    { "Add folder\u{2026}",  "studio:add-folder" },
    M.SEP,
    { "Save",           "doc:save" },
    { "Save as\u{2026}",     "doc:save-as" },
  },
  Edit = {
    { "Undo",  "doc:undo" }, { "Redo",  "doc:redo" }, M.SEP,
    { "Cut",   "doc:cut" },  { "Copy",  "doc:copy" }, { "Paste", "doc:paste" }, M.SEP,
    { "Find / replace\u{2026}", "find-replace:find" },
  },
  Selection = {
    { "Select all",  "doc:select-all" },
    { "Select word", "doc:select-word" },
    { "Select line", "doc:select-lines" },
  },
  View = {
    { "Workspace: Agent", "shell:workspace-agent" },
    { "Workspace: Edit",  "shell:workspace-edit" },
    { "Workspace: Fleet", "shell:workspace-fleet" },
    M.SEP,
    { "Toggle theme (dark/light)", "shell:toggle-theme" },
    { "Toggle session list", "studio:toggle-sidebar" },
    { "Toggle file tree",   "studio:toggle-files" },
    { "Toggle fullscreen", "core:toggle-fullscreen" },
    { "Open log",          "core:open-log" },
  },
  Go = {
    { "Go to line\u{2026}",    "doc:go-to-line" },
    { "Next tab",         "root:switch-to-next-tab" },
    { "Previous tab",     "root:switch-to-previous-tab" },
    M.SEP,
    { "Split right",      "root:split-right" },
    { "Split down",       "root:split-down" },
    { "Close pane",       "root:close" },
  },
  Agent = {
    { "New session",      "agent:new-session" },
    { "Resume session\u{2026}", "agent:resume-session" },
    { "Rename session\u{2026}", "agent:rename-session" },
    { "Delete session\u{2026}", "agent:delete-session" },
    M.SEP,
    { "Attach file\u{2026}",   "agent:attach-file" },
    { "Search chats\u{2026}",  "agent:search-sessions" },
    { "Set model\u{2026}",     "agent:set-model" },
    { "Set endpoint\u{2026}",  "agent:set-endpoint" },
    { "Set API key\u{2026}",   "agent:set-api-key" },
    { "Approval mode\u{2026}", "agent:set-mode" },
    { "Per-tool permissions\u{2026}", "agent:tool-permission" },
    { "Permissions",      "agent:show-permissions" },
    M.SEP,
    { "Explain selection", "agent:explain-selection" },
    { "Review selection",  "agent:review-selection" },
    { "Write tests for selection", "agent:test-selection" },
    M.SEP,
    { "Compact now",      "agent:compact-now" },
    { "Usage",            "agent:show-usage" },
    { "Context",          "agent:show-context" },
    { "Edit message\u{2026}", "agent:edit-message" },
    { "Cancel turn",      "agent:cancel" },
  },
  Run = {
    { "Run automation\u{2026}",    "automations:run" },
    { "New automation\u{2026}",    "automations:new" },
    { "Manage automations\u{2026}", "automations:manage" },
    M.SEP,
    { "Schedule automation\u{2026}", "automations:schedule" },
    { "Stop schedule",             "automations:stop-schedule" },
    M.SEP,
    { "ReAct until goal\u{2026}",  "agent:react" },
  },
  Fleet = {
    { "Open fleet",       "shell:workspace-fleet" },
    { "Swarm dashboard",  "agent:swarm" },
  },
  Tools = {
    { "Library\u{2026}",     "agent:library" },
    { "Tools",          "agent:show-tools" },
    { "MCP servers",    "agent:list-mcp-servers" },
    { "Add MCP server\u{2026}", "agent:add-mcp-server" },
    { "Edit mcp_servers.lua", "agent:edit-mcp-servers" },
    { "Event handlers", "agent:show-event-handlers" },
    { "Panels\u{2026}",      "studio:open-panel" },
    { "Run command\u{2026}", "agent:run-command" },
  },
  Help = {
    { "Keyboard shortcuts\u{2026}", "help:shortcuts" },
    M.SEP,
    { "Show config",        "agent:show-config" },
  },
}

-- Turn a menu into command_view chooser items ({ text, cmd, info=keybinding }).
function M.choices(menu)
  local rows = M.tree[menu]
  if not rows then return nil end
  local out = {}
  for _, r in ipairs(rows) do
    if not r.sep then
      out[#out + 1] = { text = r[1], cmd = r[2], info = keymap.get_binding(r[2]) or "" }
    end
  end
  return out
end

-- Load the shortcuts surface so `help:shortcuts` and its bindings (F1 / ?) are
-- registered -- registry is required early (by the menu bar at attach).
require "shell.shortcuts"

return M
