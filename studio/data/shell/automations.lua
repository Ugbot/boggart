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

-- ---- parameters ({{placeholders}}, ported from the old recipes) -------------
-- Every {{placeholder}} in first-appearance order, without duplicates.
function M.params(text)
  local out, seen = {}, {}
  for p in tostring(text or ""):gmatch("{{%s*([%w_%-%.]+)%s*}}") do
    if not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  return out
end

function M.fill(text, values)
  return (tostring(text or ""):gsub("{{%s*([%w_%-%.]+)%s*}}", function(p)
    return values[p] or ("{{" .. p .. "}}")
  end))
end

-- Ask for each parameter in turn (the command view is callback-driven, so this
-- is "ask for one, then in the callback ask for the rest"), then hand the filled
-- prompt to `done`.
function M.prompt_params(text, done)
  local params = M.params(text)
  local values = {}
  local function step(i)
    if i > #params then return done(M.fill(text, values)) end
    core.command_view:enter(params[i] .. ":", function(answer)
      values[params[i]] = answer
      step(i + 1)
    end, function() return {} end)
  end
  step(1)
end

-- Submit `prompt` as a turn in the AGENT workspace, so it streams and gets tool
-- approval exactly like anything you type.
local function submit_prompt(prompt)
  -- Reach the conversation. In the shell that means switching to the AGENT
  -- workspace; in the legacy composition there is no shell to switch, so just
  -- fetch the agent view directly.
  local sh = package.loaded["shell"]
  if sh and sh.attached and sh.switch then sh.switch("agent") end
  local studio = package.loaded["core.studio"]
  local v = studio and (studio.view or (studio.open_agent and studio.open_agent()))
  if not v then return end
  if v.busy then core.log("agent is busy; try again when the turn finishes"); return end
  if v.send_prompt then v:send_prompt(prompt)
  elseif v.submit then v:submit(v.expand_mentions and v:expand_mentions(prompt) or prompt) end
end

-- Run an automation now: fill any {{parameters}} first, then submit.
function M.run(name)
  local prompt = M.load(name)
  if not prompt or prompt == "" then return end
  if #M.params(prompt) > 0 then
    M.prompt_params(prompt, submit_prompt)
  else
    submit_prompt(prompt)
  end
end

-- ---- scheduling (ported from studio.schedule) -------------------------------
-- M.scheduled is the single live schedule, read by the status bar. One at a
-- time by design: a second scheduled automation replaces the first.
M.scheduled = nil

function M.stop_schedule()
  if not M.scheduled then return false end
  M.scheduled.stop = true
  M.scheduled = nil
  return true
end

-- Run `name` every `minutes`. Fixed prompts only -- a scheduled run has no one
-- to answer its {{parameters}}.
function M.schedule(name, minutes)
  local body = M.load(name)
  if not body then return false, "no such automation" end
  if #M.params(body) > 0 then
    return false, "'" .. name .. "' takes parameters; schedule only runs fixed prompts"
  end
  M.stop_schedule()
  local sched = { name = name, minutes = minutes, runs = 0, stop = false }
  M.scheduled = sched
  core.add_thread(function()
    while M.scheduled == sched and not sched.stop do
      for _ = 1, math.floor(minutes * 60 / 0.5) do
        if M.scheduled ~= sched or sched.stop then return end
        coroutine.yield(0.5)
      end
      local studio = package.loaded["core.studio"]
      local v = studio and studio.view
      if M.scheduled == sched and not sched.stop and v and not v.busy then
        sched.runs = sched.runs + 1
        v:push("system", string.format("scheduled run %d of '%s'", sched.runs, name))
        submit_prompt(body)
      end
    end
  end)
  return true
end

-- choices for a command_view chooser
function M.choices()
  local out = {}
  for _, name in ipairs(M.list()) do out[#out + 1] = { text = name, name = name } end
  return out
end

-- ---- pickers (command_view, so they work in the shell AND legacy) -----------
-- The one saved-prompt UI. The shell menu (automations:*) and the toolbar/
-- sidebar (agent:run-recipe etc.) both route here, so there is a single flow.
local function common_fuzzy(names, text)
  return require("core.common").fuzzy_match(names, text)
end

function M.run_picker()
  local names = M.list()
  if #names == 0 then core.log("no automations yet -- New automation\u{2026}"); return end
  core.command_view:enter("Run automation:", function(text, item)
    M.run(item or text)
  end, function(text) return common_fuzzy(names, text) end)
end

function M.new_prompt()
  core.command_view:enter("Automation name", function(name)
    if not name or name == "" then return end
    core.command_view:enter("Prompt for '" .. name .. "'", function(prompt)
      M.save(name, prompt or "")
      core.log("saved automation '%s'%s", name, #M.params(prompt or "") > 0
        and (" ({{" .. table.concat(M.params(prompt), "}}, {{") .. "}})") or "")
    end)
  end)
end

function M.edit_picker()
  local names = M.list()
  if #names == 0 then core.log("no automations to edit yet"); return end
  core.command_view:enter("Edit automation:", function(text, item)
    local name = item or text
    if M.load(name) then core.root_view:open_doc(core.open_doc(path(name))) end
  end, function(text) return common_fuzzy(names, text) end)
end

function M.schedule_picker()
  local names = M.list()
  if #names == 0 then core.log("no automations to schedule yet"); return end
  core.command_view:enter("Schedule automation:", function(text, item)
    local name = item or text
    core.command_view:enter("Every how many minutes:", function(mins)
      local n = tonumber(mins)
      if not n or n <= 0 then core.error("not a number of minutes"); return end
      local ok, err = M.schedule(name, n)
      if not ok then core.error("%s", err)
      else core.log("'%s' every %g min -- Stop schedule to cancel", name, n) end
    end)
  end, function(text) return common_fuzzy(names, text) end)
end

return M
