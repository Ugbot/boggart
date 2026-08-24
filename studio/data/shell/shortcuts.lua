-- shell/shortcuts.lua -- the keyboard cheatsheet. The whole modal spine (Ctrl-w
-- panes, gt workspaces, the Space leader map, normal-mode j/k) is otherwise
-- undiscoverable, so this is its one reference surface: a centered, read-only
-- overlay drawn on top of everything and dismissed on ANY key or click. It wraps
-- RootView (draw + mouse) and keymap.on_key_pressed the same way the menu-bar
-- overlay does; the wraps install lazily on first open and are cheap no-ops
-- while the panel is closed.
local core = require "core"
local style = require "core.style"
local keymap = require "core.keymap"
local command = require "core.command"

local shortcuts = {}
shortcuts.open = false

local SCRIM = { 0, 0, 0, 140 }  -- dim wash over the content behind the panel

-- The spine, spelled out. Each section is { title, { {keys, description}, ... } }.
local SECTIONS = {
  { "Panes  (Ctrl-w \u{2026})", {
    { "Ctrl-w h/j/k/l", "focus pane left / down / up / right" },
    { "Ctrl-w s / v",   "split down / right" },
    { "Ctrl-w q",       "close pane" },
  } },
  { "Workspaces", {
    { "gt / gT",         "next / previous workspace" },
    { "Ctrl-1/2/3",      "Agent / Edit / Fleet" },
    { "Space t",         "cycle workspace" },
  } },
  { "Leader  (Space \u{2026})", {
    { "Space f",  "find file" },
    { "Space a",  "Agent menu" },
    { "Space g",  "Go menu" },
    { "Space m",  "menu bar" },
    { "Space w",  "window (pane) prefix" },
    { "Space :",  "command palette" },
  } },
  { "Motion  (read-only surfaces)", {
    { "j / k",           "scroll down / up" },
    { "gg / G",          "jump to top / bottom" },
    { "Ctrl-d / Ctrl-u", "half-page down / up" },
  } },
  { "Composer  (Agent workspace)", {
    { "Tab",             "complete / commands, skills, @files" },
    { "@ then type",     "filter the file menu" },
    { "/command",        "same slash commands as the REPL / TUI" },
    { "!command",        "run a shell command" },
    { "Shift-Tab",       "cycle approval mode" },
    { "Shift-Enter / Ctrl-J", "newline" },
    { "Esc",             "cancel turn / normal mode" },
    { "Ctrl-R",          "search composer history" },
    { "{ / }",           "previous / next user prompt (normal mode)" },
    { "?",               "this cheatsheet" },
  } },
}

-- A curated set of command bindings, resolved live from the keymap so the sheet
-- never drifts from the real bindings.
local COMMANDS = {
  { "core:find-command",  "Command palette" },
  { "core:find-file",     "Find file" },
  { "doc:save",           "Save" },
  { "agent:new-session",  "New agent session" },
  { "agent:cancel",       "Cancel turn" },
  { "agent:set-mode",     "Approval mode" },
  { "agent:attach-file",  "Attach a file" },
  { "agent:history-search", "Composer history" },
  { "shell:toggle-theme", "Toggle theme" },
  { "help:shortcuts",     "This cheatsheet" },
}

-- Flatten sections + commands into draw rows: { head=... } or { keys=, desc= }.
local function rows()
  local out = { { head = "Keyboard shortcuts", title = true } }
  for _, sec in ipairs(SECTIONS) do
    out[#out + 1] = { head = sec[1] }
    for _, r in ipairs(sec[2]) do out[#out + 1] = { keys = r[1], desc = r[2] } end
  end
  out[#out + 1] = { head = "Commands" }
  for _, c in ipairs(COMMANDS) do
    out[#out + 1] = { keys = keymap.get_binding(c[1]) or "\u{2014}", desc = c[2] }
  end
  return out
end

function shortcuts.draw_overlay()
  local font = style.font
  local items = rows()
  local rowh = font:get_height() + 7
  local pad, gap = 20, 24

  local keyw, descw = 0, 0
  for _, it in ipairs(items) do
    if it.keys then keyw = math.max(keyw, font:get_width(it.keys)) end
    if it.desc then descw = math.max(descw, font:get_width(it.desc)) end
    if it.head then descw = math.max(descw, font:get_width(it.head) - keyw - gap) end
  end
  local w = pad * 2 + keyw + gap + descw
  local h = pad * 2 + #items * rowh

  local rv = core.root_view
  local sx, sy, sw, sh = rv.position.x, rv.position.y, rv.size.x, rv.size.y
  renderer.draw_rect(sx, sy, sw, sh, SCRIM)

  local x = sx + math.max(0, (sw - w) / 2)
  local y = sy + math.max(0, (sh - h) / 2)
  renderer.draw_rect(x - 1, y - 1, w + 2, h + 2, style.divider)
  renderer.draw_rect(x, y, w, h, style.background)

  local cy = y + pad
  for _, it in ipairs(items) do
    if it.head then
      renderer.draw_text(font, it.head, x + pad, cy, it.title and style.accent or style.dim)
    else
      renderer.draw_text(font, it.keys, x + pad, cy, style.text)
      renderer.draw_text(font, it.desc, x + pad + keyw + gap, cy, style.dim)
    end
    cy = cy + rowh
  end
end

-- Wrap RootView (overlay draw + swallow the dismissing click) and the key path
-- (swallow the dismissing key). Installed once, on first open; the modal spine
-- has already wrapped on_key_pressed by then, so this wrap sits OUTSIDE it and
-- gets first refusal on the dismiss stroke.
function shortcuts.install()
  if shortcuts.installed then return end
  shortcuts.installed = true

  local RootView = require "core.rootview"
  local odraw = RootView.draw
  function RootView:draw(...)
    odraw(self, ...)
    if shortcuts.open then shortcuts.draw_overlay() end
  end
  local omp = RootView.on_mouse_pressed
  function RootView:on_mouse_pressed(button, x, y, clicks)
    if shortcuts.open then shortcuts.open = false; core.redraw = true; return true end
    return omp(self, button, x, y, clicks)
  end

  local okey = keymap.on_key_pressed
  keymap.on_key_pressed = function(k)
    if shortcuts.open then
      if not keymap.is_modkey(k) then shortcuts.open = false; core.redraw = true end
      return true  -- swallow while open, so a stray stroke only dismisses
    end
    return okey(k)
  end
end

command.add(nil, {
  ["help:shortcuts"] = function()
    shortcuts.install()
    shortcuts.open = not shortcuts.open
    core.redraw = true
  end,
})
-- "?" (shift+/) opens the cheatsheet ONLY when not typing, so it can still be
-- typed in the composer or the editor. F1 always works. Bound to a separate
-- predicated command; a swallowed keypress would otherwise eat the "?".
command.add(function()
  local ok, modal = pcall(require, "shell.modal")
  return not (ok and modal and modal.typing and modal.typing())
end, {
  ["help:shortcuts-key"] = function() command.perform("help:shortcuts") end,
})
keymap.add {
  ["f1"] = "help:shortcuts",
  ["shift+/"] = "help:shortcuts-key",  -- "?" when not typing
}

return shortcuts
