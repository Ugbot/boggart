-- vimmode.lua -- studio commands over the shared lua/vimmode.lua setting.
-- The actual modal engine is studio/data/core/vim.lua; this just exposes the
-- policy (off/on/mandatory) as commands so it can be cycled or set directly
-- from the command palette or a key.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local vimmode = require "vimmode"

command.add(nil, {
  ["vim:cycle-mode"] = function()
    core.log("vim mode: %s", vimmode.cycle())
  end,
  ["vim:set-off"] = function()
    core.log("vim mode: %s", vimmode.set("off"))
  end,
  ["vim:set-on"] = function()
    core.log("vim mode: %s", vimmode.set("on"))
  end,
  ["vim:set-mandatory"] = function()
    core.log("vim mode: %s", vimmode.set("mandatory"))
  end,
})

keymap.add {
  ["ctrl+shift+v"] = "vim:cycle-mode",
  ["cmd+shift+v"] = "vim:cycle-mode",
}
