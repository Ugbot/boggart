-- Exercise real full-screen terminal applications through Bmux's local PTYs.
-- CMake registers this only when all four applications are installed.
local core = require "core"
local shell = require "shell"
local config = require "core.config"
local terminal = require "terminal"
local workspace = require "shell.workspaces.bmux"
local json = require "json"

local home = assert(os.getenv("BOGGART_HOME"))
local htop_bin = assert(os.getenv("BMUX_TEST_HTOP"))
local less_bin = assert(os.getenv("BMUX_TEST_LESS"))
local tmux_bin = assert(os.getenv("BMUX_TEST_TMUX"))
local vim_bin = assert(os.getenv("BMUX_TEST_VIM"))
local htop, less, tmux, vim

local function frame()
  core.redraw = true
  core.frame_start = system.get_time()
  core.step()
end

local function content(view)
  view:sync(true)
  local lines = {}
  for y = 1, view.rows do
    local cells = {}
    for _, cell in ipairs(view.terminal:row(y).cells) do cells[#cells + 1] = cell.text end
    lines[#lines + 1] = table.concat(cells)
  end
  return table.concat(lines, "\n")
end

local function wait_for(check, description, view)
  local deadline = system.get_time() + 12
  repeat
    frame()
    if check() then return end
    system.wait_event(0.04)
  until system.get_time() > deadline
  error(description .. " timed out; process=" .. json.encode(view.terminal:process_state())
    .. "\n" .. content(view))
end

local function assert_rgb(view, marker_text, value)
  for y = 1, view.rows do
    local row = view.terminal:row(y)
    local chars = {}
    for _, cell in ipairs(row.cells) do chars[#chars + 1] = cell.text end
    local x = table.concat(chars):find(marker_text, 1, true)
    if x then
      assert(row.cells[x].style.fg == (terminal.COLOR_RGB | value),
        marker_text .. " lost RGB color: " .. json.encode(row.cells[x].style))
      return
    end
  end
  error(marker_text .. " was not rendered")
end

local function close_app(view, input, description)
  view:send(input)
  wait_for(function() return view.dead and view.state and not view.state.alternate end,
    description .. " clean exit", view)
  view:try_close(function() end)
end

local ok, err = xpcall(function()
  config.bmux_server = false
  shell.switch("bmux")

  htop = workspace.open(nil, { cmd = htop_bin, args = { "--delay=0.5" }, title = "htop smoke" })
  wait_for(function()
    return htop.state and htop.state.alternate and content(htop):find("Tasks", 1, true)
  end, "htop alternate screen", htop)
  assert(not htop.dead, "htop remains live in alternate screen")
  close_app(htop, "q", "htop")

  local vim_path = home .. "/vim-smoke.txt"
  local fixture = assert(io.open(vim_path, "wb"))
  fixture:write("vim native test\n")
  fixture:close()
  vim = workspace.open(nil, { cmd = vim_bin,
    args = { "-Nu", "NONE", "-n", "-i", "NONE", vim_path }, title = "Vim smoke" })
  wait_for(function()
    return vim.state and vim.state.alternate and content(vim):find("vim native test", 1, true)
  end, "Vim alternate screen", vim)
  close_app(vim, "\27:q!\r", "Vim")

  local less_path = home .. "/less-smoke.txt"
  fixture = assert(io.open(less_path, "wb"))
  fixture:write("\27[38;2;18;52;86mLESS_RGB\27[0m café 🦊 ──\nsecond line\n")
  fixture:close()
  less = workspace.open(nil, { cmd = less_bin, args = { "-R", less_path }, title = "Less smoke" })
  wait_for(function()
    return less.state and less.state.alternate and content(less):find("LESS_RGB", 1, true)
  end, "Less alternate screen", less)
  assert_rgb(less, "LESS_RGB", 0x123456)
  assert(content(less):find("café 🦊 ──", 1, true), "Less preserves Unicode text")
  close_app(less, "q", "Less")

  local conf_path = home .. "/tmux-smoke.conf"
  fixture = assert(io.open(conf_path, "wb"))
  fixture:write('set -g default-terminal "tmux-256color"\n'
    .. 'set -as terminal-features ",xterm-256color:RGB"\n'
    .. 'set -g status-style "fg=#123456,bg=#654321"\n'
    .. 'set -g status-left "RGB_STATUS"\n')
  fixture:close()
  tmux = workspace.open(nil, { cmd = tmux_bin, args = {
    "-L", "boggart-app-smoke", "-f", conf_path, "new-session", "-A", "-s", "boggart-app-smoke",
    [[printf '\033[38;2;18;52;86mTMUX_RGB\033[0m\n'; sleep 60]],
  }, title = "tmux smoke" })
  wait_for(function()
    return tmux.state and tmux.state.alternate and content(tmux):find("RGB_STATUS", 1, true)
      and content(tmux):find("TMUX_RGB", 1, true)
  end, "tmux alternate screen and RGB content", tmux)
  assert(not tmux.dead, "tmux stays attached")
  assert_rgb(tmux, "TMUX_RGB", 0x123456)
  tmux:send("\2d")
  wait_for(function() return tmux.dead and tmux.state and not tmux.state.alternate end,
    "tmux detach", tmux)
  tmux:try_close(function() end)

  print("BMUX apps: Vim, Less, htop and tmux alternate screens; Less Unicode/RGB; tmux RGB; exit and detach pass")
end, debug.traceback)

if tmux then
  os.execute(string.format("%q -L boggart-app-smoke kill-server >/dev/null 2>&1", tmux_bin))
end
if not ok then
  io.stderr:write(tostring(err), "\n")
  rawset(_G, "STUDIO_BOOT_FAILED", true)
end
core.quit(true)
