-- shell/automations.lua -- ONE concept for "save a prompt and run it", merging
-- what used to be three overlapping things (recipes / workflows / schedule). An
-- automation is a saved, named prompt (with @mentions) that you can run now;
-- scheduling and multi-step pipelines layer on the same store. One store
-- (~/.boggart/automations/<name>.txt), one menu home (Run), one UI (a chooser).
local core = require "core"

local M = {}

local function dir()
  local root = (bog and bog.userdir) or (sys.home() .. "/.boggart")
  local d = root .. "/automations"
  sys.mkdir_p(d)
  return d
end

local function path(name) return dir() .. "/" .. (name:gsub("[^%w_%-]", "_")) .. ".txt" end

function M.list()
  local out = {}
  for _, f in ipairs(sys.listdir(dir()) or {}) do
    local n = f:match("^(.+)%.txt$")
    if n then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end

function M.load(name)
  local f = io.open(path(name), "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

function M.save(name, prompt)
  local f = io.open(path(name), "w"); if not f then return false end
  f:write(prompt or ""); f:close(); return true
end

function M.remove(name) os.remove(path(name)); return true end

-- Run an automation: submit its prompt as a turn in the AGENT workspace, so it
-- streams and gets tool approval exactly like anything you type.
function M.run(name)
  local prompt = M.load(name)
  if not prompt or prompt == "" then return end
  require("shell").switch("agent")
  local studio = package.loaded["core.studio"]
  local v = studio and studio.view
  if v and v.submit then
    if v.busy then core.log("agent is busy; try again when the turn finishes"); return end
    v:submit(v.expand_mentions and v:expand_mentions(prompt) or prompt)
  end
end

-- choices for a command_view chooser
function M.choices()
  local out = {}
  for _, name in ipairs(M.list()) do out[#out + 1] = { text = name, name = name } end
  return out
end

return M
