-- shell/modal.lua -- the app-wide neovim spine. Extends the modal model up out
-- of the text buffer so a neovim user drives the WHOLE shell: `Ctrl-w` panes,
-- `g`/`gt` + leader navigation, and normal-mode `j k gg G Ctrl-d/u` in every
-- read-only surface. It installs by wrapping keymap.on_key_pressed so it sees
-- each stroke first; anything it doesn't claim falls through untouched, and it
-- NEVER hijacks a surface that is actively taking typed text (insert mode, the
-- agent composer, the ":" line).
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local style = require "core.style"

local modal = {}
modal.pending = nil -- nil | "window" | "g" | "leader"

-- Is the focused surface actively accepting typed text?
--
-- The spine owns this question but no longer answers it by reaching into vim's
-- state or the composer's edit_mode -- each mode-bearing view answers for itself
-- through a uniform :is_text_input() (DocView via vim, AgentView via edit_mode,
-- the command view always). So the three "mode machines" are now clients of one
-- query instead of interrogating each other, and a new modal surface only has to
-- implement is_text_input() to take part.
local function typing()
  local v = core.active_view
  if not v then return false end
  if v == core.command_view then return true end
  if v.is_text_input then return v:is_text_input() end
  return false
end
modal.typing = typing

-- A command_view chooser over { {text, cmd, info}, ... } -- how menus and
-- which-key render for P1 (anchored dropdowns are the P6 visual pass).
function modal.chooser(label, choices, on_pick)
  core.command_view:enter(label, function(text, item)
    local pick = item
    if not pick then
      for _, c in ipairs(choices) do
        if c.text:lower() == (text or ""):lower() then pick = c end
      end
    end
    if pick then on_pick(pick) end
  end, function(text)
    return common.fuzzy_match(choices, text or "")
  end)
end

local function scroll(view, lines)
  if not view then return end
  -- A view may define its own answer to a spine scroll. The fleet roster moves
  -- its selection rather than panning pixels -- a dashboard of fixed panes has
  -- no single scrollable body, so "down" most usefully means "the next agent",
  -- and gg/G (the ±1e9 sweeps) fall to the ends the same way. Everything else
  -- takes the default pixel scroll.
  if view.on_spine_scroll then view:on_spine_scroll(lines); core.redraw = true; return end
  if not view.scroll then return end
  local lh = (view.get_line_height and view:get_line_height()) or 16
  view.scroll.to.y = math.max(0, (view.scroll.to.y or 0) + lines * lh)
  core.redraw = true
end

-- Ctrl-w window map (nvim). j/k = down/up across splits, s/v = split, q = close.
local WIN = {
  h = "root:switch-to-left",  j = "root:switch-to-down",
  k = "root:switch-to-up",    l = "root:switch-to-right",
  s = "root:split-down",      v = "root:split-right",
  q = "root:close",           c = "root:close",
  w = "root:switch-to-right",
}

function modal.leader_open()
  modal.pending = "leader"
  if core.status_view then
    core.status_view:show_message("!", style.accent,
      "leader:  f find-file   a agent   g go   m menu   w window   t workspace   : command")
  end
  return true
end

-- Open a menu-bar menu via the SAME anchored dropdown the mouse uses (with its
-- keyboard nav), not the old command_view chooser. Guarded: the menu bar only
-- exists once shell.attach() has run.
local function open_menu(shell, name)
  if shell.menubar then shell.menubar:open_menu(name) end
end

local function leader_key(k)
  local shell = require "shell"
  modal.pending = nil
  if k == "f" or k == "b" then command.perform("core:find-file")
  elseif k == "a" then open_menu(shell, "Agent")
  elseif k == "g" then open_menu(shell, "Go")
  elseif k == "m" then open_menu(shell, shell.menubar and shell.menubar.menus[1])
  elseif k == "w" then modal.pending = "window"
  elseif k == "t" then shell.cycle_workspace(1)
  elseif k == ";" or k == ":" or k == "space" then command.perform("core:find-command")
  end
  return true
end

-- Returns true if the stroke was consumed.
function modal.intercept(k)
  if keymap.is_modkey(k) then return false end
  local stroke = keymap.key_to_stroke(k)

  -- An open menu-bar dropdown owns the keyboard: arrows move / switch menus,
  -- Enter runs the row, Esc closes. Checked first so it works over any surface.
  local shell = package.loaded["shell"]
  if shell and shell.menubar and shell.menubar.open then
    local mb = shell.menubar
    if k == "escape" then mb:close(); return true
    elseif k == "up" then mb:move_hover(-1); return true
    elseif k == "down" then mb:move_hover(1); return true
    elseif k == "left" then mb:cycle_title(-1); return true
    elseif k == "right" then mb:cycle_title(1); return true
    elseif k == "return" or k == "keypad enter" then mb:activate_hover(); return true
    end
  end

  if modal.pending == "window" then
    modal.pending = nil
    local cmd = WIN[k]; if cmd then command.perform(cmd) end
    return true
  elseif modal.pending == "g" then
    modal.pending = nil
    if k == "t" then require("shell").cycle_workspace(keymap.modkeys.shift and -1 or 1)
    elseif k == "g" then scroll(core.active_view, -1e9) end
    return true
  elseif modal.pending == "leader" then
    return leader_key(k)
  end

  if typing() then return false end

  -- Ctrl-w is the pane/window prefix on read-only surfaces, but in a text field
  -- it is the word-delete every editor binds -- so it is claimed only once the
  -- typing() guard above has let a field keep it.
  if stroke == "ctrl+w" then modal.pending = "window"; return true end

  if k == "g" then modal.pending = "g"; return true end
  if k == "space" then return modal.leader_open() end
  if k == "j" then scroll(core.active_view, 1); return true end
  if k == "k" then scroll(core.active_view, -1); return true end
  if stroke == "ctrl+d" then scroll(core.active_view, 12); return true end
  if stroke == "ctrl+u" then scroll(core.active_view, -12); return true end
  if stroke == "shift+g" then scroll(core.active_view, 1e9); return true end
  return false
end

function modal.install()
  if modal.installed then return end
  modal.installed = true
  local orig = keymap.on_key_pressed
  keymap.on_key_pressed = function(k)
    if modal.intercept(k) then return true end
    return orig(k)
  end
end

return modal
