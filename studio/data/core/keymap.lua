local command = require "core.command"
local keymap = {}

keymap.modkeys = {}
keymap.map = {}
keymap.reverse_map = {}

-- Command was missing entirely. SDL reports it as "left gui"/"right gui", and
-- an unknown modifier is simply dropped -- so on macOS every Cmd chord arrived
-- as its bare letter: Cmd+C was "c", Cmd+V was "v", and nothing bound to them
-- ran. On a Mac that is not a missing shortcut, it is the whole muscle memory
-- of the platform doing nothing.
local modkey_map = {
  ["left ctrl"]   = "ctrl",
  ["right ctrl"]  = "ctrl",
  ["left shift"]  = "shift",
  ["right shift"] = "shift",
  ["left alt"]    = "alt",
  ["right alt"]   = "altgr",
  ["left gui"]    = "cmd",
  ["right gui"]   = "cmd",
  -- macOS: SDL_GetKeyName reports the Command and Option keys as "left/right
  -- command" and "left/right option", NOT the "gui"/"alt" names above. Without
  -- these, keymap.modkeys.cmd/alt never got set on a Mac, so EVERY Cmd- and
  -- Option- shortcut (copy/paste/cut/select-all included) silently arrived as a
  -- bare key and did nothing. This is the fix for "the text view stuff is borked".
  ["left command"]  = "cmd",
  ["right command"] = "cmd",
  ["left option"]   = "alt",
  ["right option"]  = "altgr",
}

local modkeys = { "cmd", "ctrl", "alt", "altgr", "shift" }

local function key_to_stroke(k)
  local stroke = ""
  for _, mk in ipairs(modkeys) do
    if keymap.modkeys[mk] then
      stroke = stroke .. mk .. "+"
    end
  end
  return stroke .. k
end
-- Exposed so the shell's modal spine (studio/data/shell/modal.lua) can compute
-- the same stroke when it wraps on_key_pressed to capture Ctrl-w / g / leader.
keymap.key_to_stroke = key_to_stroke
keymap.is_modkey = function(k) return modkey_map[k] ~= nil end


function keymap.add(map, overwrite)
  for stroke, commands in pairs(map) do
    if type(commands) == "string" then
      commands = { commands }
    end
    if overwrite then
      keymap.map[stroke] = commands
    else
      keymap.map[stroke] = keymap.map[stroke] or {}
      for i = #commands, 1, -1 do
        table.insert(keymap.map[stroke], 1, commands[i])
      end
    end
    -- reverse_map answers "what stroke shows for this command" (the cheatsheet).
    -- Keep the first stroke a command is bound to rather than letting the last
    -- keymap.add win: add-order is not fixed once plugins and the Cmd mirror run,
    -- so last-writer-wins made get_binding flip between runs. An explicit
    -- overwrite is a deliberate rebind and does update the shown stroke.
    for _, cmd in ipairs(commands) do
      if overwrite or keymap.reverse_map[cmd] == nil then
        keymap.reverse_map[cmd] = stroke
      end
    end
  end
end


function keymap.get_binding(cmd)
  
return keymap.reverse_map[cmd]
end


function keymap.on_key_pressed(k)
  local mk = modkey_map[k]
  if mk then
    keymap.modkeys[mk] = true
    -- work-around for windows where `altgr` is treated as `ctrl+alt`
    if mk == "altgr" then
      keymap.modkeys["ctrl"] = false
    end
  else
    local stroke = key_to_stroke(k)
    local commands = keymap.map[stroke]
    if commands then
      for _, cmd in ipairs(commands) do
        if command.perform(cmd) then return true end
      end
    end
    -- Nothing claimed the stroke: offer it to the focused view.
    --
    -- Upstream stops at the line above, because in a text editor every key
    -- belongs to a command and a View is a passive rectangle. That is no longer
    -- true here: the chat composer, the settings form and the workflow editor
    -- are text fields that own their own editing keys, and without this line
    -- their Enter, Backspace and arrows silently did nothing at all -- typing
    -- worked, because on_text_input goes to the view, and every other key was
    -- swallowed. Every probe missed it by calling on_key_pressed directly,
    -- which is the one thing the real keyboard never does.
    --
    -- Commands still win, so a binding always beats a view. The view sees the
    -- full stroke ("ctrl+u", not "u") so it can tell them apart.
    local core = require "core"
    local view = core.active_view
    if view and view.on_key_pressed and view:on_key_pressed(stroke) then
      return true
    end
  end
  return false
end


function keymap.on_key_released(k)
  local mk = modkey_map[k]
  if mk then
    keymap.modkeys[mk] = false
  end
end


keymap.add {
  ["ctrl+shift+p"] = "core:find-command",
  ["ctrl+p"] = "core:find-file",
  ["ctrl+o"] = "core:open-file",
  ["ctrl+n"] = "core:new-doc",
  ["alt+return"] = "core:toggle-fullscreen",

  ["alt+shift+j"] = "root:split-left",
  ["alt+shift+l"] = "root:split-right",
  ["alt+shift+i"] = "root:split-up",
  ["alt+shift+k"] = "root:split-down",
  ["alt+j"] = "root:switch-to-left",
  ["alt+l"] = "root:switch-to-right",
  ["alt+i"] = "root:switch-to-up",
  ["alt+k"] = "root:switch-to-down",

  ["ctrl+w"] = "root:close",
  ["ctrl+tab"] = "root:switch-to-next-tab",
  ["ctrl+shift+tab"] = "root:switch-to-previous-tab",
  ["ctrl+pageup"] = "root:move-tab-left",
  ["ctrl+pagedown"] = "root:move-tab-right",
  ["alt+1"] = "root:switch-to-tab-1",
  ["alt+2"] = "root:switch-to-tab-2",
  ["alt+3"] = "root:switch-to-tab-3",
  ["alt+4"] = "root:switch-to-tab-4",
  ["alt+5"] = "root:switch-to-tab-5",
  ["alt+6"] = "root:switch-to-tab-6",
  ["alt+7"] = "root:switch-to-tab-7",
  ["alt+8"] = "root:switch-to-tab-8",
  ["alt+9"] = "root:switch-to-tab-9",

  ["ctrl+f"] = "find-replace:find",
  ["ctrl+r"] = "find-replace:replace",
  ["f3"] = "find-replace:repeat-find",
  ["shift+f3"] = "find-replace:previous-find",
  ["ctrl+g"] = "doc:go-to-line",
  ["ctrl+s"] = "doc:save",
  ["ctrl+shift+s"] = "doc:save-as",

  ["ctrl+z"] = "doc:undo",
  ["ctrl+y"] = "doc:redo",
  ["ctrl+x"] = "doc:cut",
  ["ctrl+c"] = "doc:copy",
  ["ctrl+v"] = "doc:paste",
  ["escape"] = { "command:escape", "doc:select-none" },
  ["tab"] = { "command:complete", "doc:indent" },
  ["shift+tab"] = "doc:unindent",
  ["backspace"] = "doc:backspace",
  ["shift+backspace"] = "doc:backspace",
  ["alt+n"] = "marks:next-change",
  ["alt+p"] = "marks:previous-change",
  ["alt+r"] = "marks:revert-change",
  ["ctrl+backspace"] = "doc:delete-to-previous-word-start",
  ["ctrl+shift+backspace"] = "doc:delete-to-previous-word-start",
  ["delete"] = "doc:delete",
  ["shift+delete"] = "doc:delete",
  ["ctrl+delete"] = "doc:delete-to-next-word-end",
  ["ctrl+shift+delete"] = "doc:delete-to-next-word-end",
  ["return"] = { "command:submit", "doc:newline" },
  ["keypad enter"] = { "command:submit", "doc:newline" },
  ["ctrl+return"] = "doc:newline-below",
  ["ctrl+shift+return"] = "doc:newline-above",
  ["ctrl+j"] = "doc:join-lines",
  ["ctrl+a"] = "doc:select-all",
  ["ctrl+d"] = { "find-replace:select-next", "doc:select-word" },
  ["ctrl+l"] = "doc:select-lines",
  ["ctrl+/"] = "doc:toggle-line-comments",
  ["ctrl+up"] = "doc:move-lines-up",
  ["ctrl+down"] = "doc:move-lines-down",
  ["ctrl+shift+d"] = "doc:duplicate-lines",
  ["ctrl+shift+k"] = "doc:delete-lines",

  ["left"] = "doc:move-to-previous-char",
  ["right"] = "doc:move-to-next-char",
  ["up"] = { "command:select-previous", "doc:move-to-previous-line" },
  ["down"] = { "command:select-next", "doc:move-to-next-line" },
  ["ctrl+left"] = "doc:move-to-previous-word-start",
  ["ctrl+right"] = "doc:move-to-next-word-end",
  ["ctrl+["] = "doc:move-to-previous-block-start",
  ["ctrl+]"] = "doc:move-to-next-block-end",
  ["home"] = "doc:move-to-start-of-line",
  ["end"] = "doc:move-to-end-of-line",
  ["ctrl+home"] = "doc:move-to-start-of-doc",
  ["ctrl+end"] = "doc:move-to-end-of-doc",
  ["pageup"] = "doc:move-to-previous-page",
  ["pagedown"] = "doc:move-to-next-page",

  ["shift+left"] = "doc:select-to-previous-char",
  ["shift+right"] = "doc:select-to-next-char",
  ["shift+up"] = "doc:select-to-previous-line",
  ["shift+down"] = "doc:select-to-next-line",
  ["ctrl+shift+left"] = "doc:select-to-previous-word-start",
  ["ctrl+shift+right"] = "doc:select-to-next-word-end",
  ["ctrl+shift+["] = "doc:select-to-previous-block-start",
  ["ctrl+shift+]"] = "doc:select-to-next-block-end",
  ["shift+home"] = "doc:select-to-start-of-line",
  ["shift+end"] = "doc:select-to-end-of-line",
  ["ctrl+shift+home"] = "doc:select-to-start-of-doc",
  ["ctrl+shift+end"] = "doc:select-to-end-of-doc",
  ["shift+pageup"] = "doc:select-to-previous-page",
  ["shift+pagedown"] = "doc:select-to-next-page",
}


-- macOS expects Command for the editing verbs. Rather than rewrite every
-- binding, mirror the ones muscle memory reaches for -- and only those, so a
-- Cmd chord that means something else here is not silently claimed. The
-- platform question goes to the capability layer, which is where this codebase
-- asks it; nothing sniffs an OS name directly.
if sys and sys.caps and sys.caps().name == "macos" then
  local mirror = {
    ["ctrl+c"] = "cmd+c", ["ctrl+v"] = "cmd+v", ["ctrl+x"] = "cmd+x",
    ["ctrl+a"] = "cmd+a", ["ctrl+z"] = "cmd+z", ["ctrl+y"] = "cmd+y",
    ["ctrl+f"] = "cmd+f", ["ctrl+p"] = "cmd+p", ["ctrl+s"] = "cmd+s",
    ["ctrl+w"] = "cmd+w", ["ctrl+n"] = "cmd+n", ["ctrl+return"] = "cmd+return",
    ["ctrl+shift+p"] = "cmd+shift+p", ["ctrl+o"] = "cmd+o",
  }
  local add = {}
  for from, to in pairs(mirror) do
    local cmds = keymap.map[from]
    if cmds then
      local copy = {}
      for i, c in ipairs(cmds) do copy[i] = c end
      add[to] = copy
    end
  end
  keymap.add(add)
end

return keymap
