-- uidiscover.lua -- can a person FIND what the studio can do?
--
-- Run with `ninja ui-discover`. Two failures, both of which had really happened:
--
--   1. A menu row pointing at a command that does not exist. The row draws,
--      you click it, nothing happens -- the worst kind of broken, because it
--      looks fine in a screenshot.
--   2. A PRODUCT-surface command with no menu home. On the day this was written
--      the studio had 248 commands and 76 of them were in a menu; recipes,
--      voice, agent-authored panels and the library's own verbs were reachable
--      only if you already knew the keystroke. A feature nobody can find is a
--      feature nobody has, and the fix is cheap, so it is worth a gate.
--
-- "Product surface" deliberately means agent:/studio:/shell:/service:/
-- automations:/library:/swarm: -- what boggart itself offers. It does NOT mean
-- doc:/vim:/marks:/root:, which are editor motions people reach by key and
-- which would drown any menu that tried to list them.
--
-- INTERNAL is the escape hatch, and every entry needs a reason. It is not
-- "commands we did not get round to"; it is commands that would be WRONG in a
-- menu: in-widget editing keys, and clipboard verbs that already appear in Edit
-- under their generic names.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"

local INTERNAL = {
  -- the agent composer's clipboard verbs: Edit already lists cut/copy/paste,
  -- and these are the same act aimed at whichever field has focus
  ["agent:copy"] = true, ["agent:cut"] = true, ["agent:paste"] = true,
  ["agent:select-all"] = true,
  -- the library panel's own search box: backspace/escape/return inside a
  -- widget are not menu items in any application ever written
  ["library:search-backspace"] = true, ["library:search-cancel"] = true,
  ["library:search-commit"] = true,
  -- File already has "Open file…" (core:open-file); this is the same act
  ["studio:open-file"] = true,
}

local PRODUCT = { "agent", "studio", "shell", "service", "automations", "library",
                  "swarm", "project" }

local problems = {}
local function check(ok, msg) if not ok then problems[#problems + 1] = msg end end

core.add_thread(function()
  for _ = 1, 20 do core.redraw = true; coroutine.yield(0.04) end

  local registry = require "shell.registry"
  local inmenu, rows_total = {}, 0
  for menu, rows in pairs(registry.tree) do
    for _, r in ipairs(rows) do
      if not r.sep then
        rows_total = rows_total + 1
        inmenu[r[2]] = menu
        check(command.map[r[2]] ~= nil, string.format(
          "menu row %s -> %q is not a command that exists (it draws and does nothing)",
          menu, r[2]))
      end
    end
  end

  local hidden, total = {}, 0
  for name in pairs(command.map) do
    local prefix = name:match("^([^:]+):")
    local is_product = false
    for _, p in ipairs(PRODUCT) do if p == prefix then is_product = true end end
    if is_product then
      total = total + 1
      if not inmenu[name] and not INTERNAL[name] then
        hidden[#hidden + 1] = string.format("%s (key: %s)", name,
          tostring(keymap.get_binding(name) or "none"))
      end
    end
  end
  table.sort(hidden)
  for _, h in ipairs(hidden) do
    check(false, "no menu reaches " .. h .. " -- add it to shell/registry.lua "
      .. "or justify it in uidiscover.lua's INTERNAL list")
  end

  -- The anchored dropdown has to be INSTALLED, not merely written. It was
  -- wired to the model and permission-mode chips and never installed, so
  -- menu.show() set a flag nothing drew: clicking either chip did nothing at
  -- all, and no test noticed because the code was all present and correct.
  local menu = require "core.menu"
  check(menu._installed == true,
    "core.menu is not installed -- the model/mode dropdowns will not draw")

  -- ...and the model dropdown has to contain models. It used to offer exactly
  -- two rows (the current model and "Enter model..."), which looks like a
  -- picker and behaves like a text prompt.
  command.perform("agent:set-model")
  check(menu.open, "agent:set-model did not open a dropdown")
  local rows, checked = 0, 0
  for _, it in ipairs(menu.items or {}) do
    if not it.heading then rows = rows + 1 end
    if it.checked then checked = checked + 1 end
  end
  check(rows >= 5, "the model dropdown offers only " .. rows
    .. " choice(s) -- it should list the catalog")
  check(checked <= 1, "the model dropdown marks " .. checked
    .. " rows as current; at most one can be")
  menu.hide()

  -- The palette has to be reachable without knowing the palette exists.
  check(inmenu["core:find-command"] ~= nil,
    "the command palette itself is not in any menu")
  check(keymap.get_binding("core:find-command") ~= nil,
    "the command palette has no key binding")

  if #problems > 0 then
    io.write("FAIL\n")
    for _, p in ipairs(problems) do io.write("  - " .. p .. "\n") end
    io.flush()
    os.exit(1)
  end
  io.write(string.format(
    "ok  discoverable: %d menu rows, %d product commands, %d reachable, %d internal by design\n",
    rows_total, total, total - #hidden - 0, (function()
      local n = 0; for _ in pairs(INTERNAL) do n = n + 1 end; return n
    end)()))
  io.flush()
  os.exit(0)
end)
