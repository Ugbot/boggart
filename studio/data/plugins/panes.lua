-- panes.lua -- phase 1 of docs/studio-panels.md: finish pane navigation on
-- top of the Node/RootView split tree. root:split-{left,right,up,down} and
-- root:switch-to-{left,right,up,down,next-tab,previous-tab} already live in
-- core/commands/root.lua and already do what the spec asks of them (split
-- opens an EmptyView or re-opens the current doc; switch-to-* focuses the
-- adjacent leaf) -- this file does not redeclare those names, since
-- command.add asserts a command is not already registered. What is missing
-- is pane-scoped close, cross-pane cycling, zoom and balance, added here with
-- their own command.add + keymap.add so core/commands/root.lua and
-- core/keymap.lua stay untouched.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"


local function active_node()
  return core.root_view:get_active_node()
end

local function root()
  return core.root_view.root_node
end


-- Guard every command the same way root.lua's own split/switch commands do:
-- a no-op while focus sits in a locked dock (sidebar, menu bar).
local function unlocked()
  local node = active_node()
  return node ~= nil and not node:get_locked_size()
end


command.add(unlocked, {
  ["root:close-pane"] = function()
    active_node():close_active_view(root())
  end,

  ["root:next-pane"] = function()
    local leaves = root():get_leaves()
    local node = active_node()
    for i, n in ipairs(leaves) do
      if n == node then
        core.set_active_view(leaves[i % #leaves + 1].active_view)
        return
      end
    end
  end,

  ["root:previous-pane"] = function()
    local leaves = root():get_leaves()
    local node = active_node()
    for i, n in ipairs(leaves) do
      if n == node then
        core.set_active_view(leaves[(i - 2) % #leaves + 1].active_view)
        return
      end
    end
  end,

  -- Spec names (docs/studio-panels.md): a later modal.lua binds Ctrl-w z / = to
  -- these exact names, so do not rename them.
  ["root:zoom"] = function()
    active_node():get_content_root(root()):toggle_zoom()
  end,

  ["root:balance"] = function()
    active_node():get_content_root(root()):balance()
  end,
})

-- Directional focus already exists as root:switch-to-{dir} in commands/root.lua;
-- do not duplicate it. The keymap below points Ctrl-Alt-arrows at those.


-- Keymap. lite's engine (core/keymap.lua) binds a single stroke straight to a
-- command list -- there is no native multi-key sequence. The one prefix this
-- codebase has is shell/modal.lua's hand-rolled Ctrl-w "pending" state
-- machine, and it already claims h/j/k/l/s/v/q/c/w for switch-to-*,
-- split-down, split-right and close (its private WIN table, out of this
-- plugin's ownership) -- so Ctrl-w s/v/c already reach split-down,
-- split-right and close today. There is no free letter left in WIN for zoom
-- or for the pane-scoped commands added here, and WIN is not extensible from
-- outside modal.lua, so those get direct single-stroke bindings instead
-- (the spec's documented fallback: "else use ctrl+alt+arrows").
keymap.add {
  ["ctrl+alt+left"]  = "root:switch-to-left",
  ["ctrl+alt+right"] = "root:switch-to-right",
  ["ctrl+alt+up"]    = "root:switch-to-up",
  ["ctrl+alt+down"]  = "root:switch-to-down",
  ["ctrl+alt+n"] = "root:next-pane",
  ["ctrl+alt+p"] = "root:previous-pane",
  ["ctrl+alt+w"] = "root:close-pane",
  ["ctrl+alt+z"] = "root:zoom",
  ["ctrl+alt+b"] = "root:balance",
}
