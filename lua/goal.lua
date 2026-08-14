-- goal.lua -- run turns toward a goal until a done-check passes, or a budget is
-- spent. The difference between an agent that answers and one that achieves.
--
-- A goal is three things:
--   * a task       -- what to work toward (the first turn's instruction);
--   * a done-check -- how we know it is achieved;
--   * a budget     -- the hard turn cap that makes "run until" safe rather than
--                     "run forever". A goal is NEVER unbounded.
--
-- The supervisor runs a turn, re-checks, and feeds the check's own output back
-- as the next turn's context -- a failing test, a missing file, a fact that is
-- not yet set -- so the model steers itself with evidence instead of a guess.
--
-- Two families of check. Deterministic ones (function / shell / fact / exists)
-- are reliable and are what the tests exercise. The default, when no check is
-- given, is model-judged: the model is told to end its reply with a sentinel
-- once the goal is met, and the loop watches the stream for it -- no second
-- model call. The turn runner is injectable, so the loop, the budget and every
-- deterministic check are testable with no model and no tty.
local M = {}

-- The anti-runaway cap. Every goal inherits this unless it asks for fewer; a
-- caller may raise it, but there is always a finite ceiling.
M.DEFAULT_MAX_TURNS = 8

-- The token the model emits to declare the goal met, in model-judged mode. Kept
-- distinctive so it will not appear by accident in ordinary prose.
M.SENTINEL = "<<GOAL-MET>>"

-- ---- deterministic checks --------------------------------------------------
-- Each check is a function () -> met:boolean, detail:string. detail is the
-- evidence fed back to the next turn, so it should say *why* not-yet-met.

local function trim_tail(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return "...(truncated)...\n" .. s:sub(#s - n + 1)
end

-- Run a shell command, capturing stdout+stderr and the exit code. io.popen is
-- blocking (no scheduler yield, unlike sys.exec), which is what the REPL wants;
-- the goal's own turn cap bounds how many times it runs.
local function run_shell(cmd)
  local f = io.popen(cmd .. " 2>&1", "r")
  if not f then return 1, "could not launch: " .. cmd end
  local out = f:read("*a") or ""
  local ok, _, code = f:close()
  local exit = code or (ok and 0 or 1)
  return exit, out
end

-- compile a `done` spec into a check function.
local function compile(done)
  if type(done) == "function" then return done end
  if type(done) ~= "table" then
    return function() return false, "no done-check" end
  end

  if done.shell then
    return function()
      local exit, out = run_shell(done.shell)
      if exit == 0 then return true, "`" .. done.shell .. "` succeeded" end
      return false, "`" .. done.shell .. "` exited " .. tostring(exit)
        .. ":\n" .. trim_tail(out, 1500)
    end
  end

  if done.exists then
    return function()
      if sys.stat(done.exists) then return true, done.exists .. " exists" end
      return false, done.exists .. " does not exist yet"
    end
  end

  if done.fact ~= nil then
    return function()
      local cur = bog.blackboard and bog.blackboard.get(done.fact)
      local want = done.is
      local met = (want == nil) and (cur ~= nil) or (tostring(cur) == tostring(want))
      if met then return true, "fact '" .. tostring(done.fact) .. "' is " .. tostring(cur) end
      return false, "fact '" .. tostring(done.fact) .. "' is " .. tostring(cur)
        .. (want ~= nil and (", want " .. tostring(want)) or " (unset)")
    end
  end

  return function() return false, "unrecognised done-check" end
end

-- ---- the prompts fed to each turn ------------------------------------------
-- Model-judged goals get the sentinel instruction; checked goals do not (the
-- check, not the model, decides). The continuation carries the last check's
-- detail so the model sees the current obstacle.

local function sentinel_note(model_judged)
  if not model_judged then return "" end
  return "\n\nWhen the goal is fully and verifiably achieved -- not before -- end "
    .. "your reply with the exact token " .. M.SENTINEL .. " on its own line. Do "
    .. "not emit it while any part remains undone."
end

local function first_prompt(task, model_judged)
  return "Goal: " .. task .. "\n\nWork toward this goal now." .. sentinel_note(model_judged)
end

local function continue_prompt(task, detail, turn, max, model_judged)
  local L = {
    "Goal: " .. task,
    "",
    "The goal is not yet met (turn " .. turn .. " of at most " .. max .. ").",
  }
  if detail and detail ~= "" then
    L[#L + 1] = ""
    L[#L + 1] = "Current obstacle:"
    L[#L + 1] = detail
  end
  L[#L + 1] = ""
  L[#L + 1] = "Continue working toward the goal."
  return table.concat(L, "\n") .. sentinel_note(model_judged)
end

-- ---- the supervisor --------------------------------------------------------
-- spec = {
--   task      = string,                       -- required
--   done      = function | {shell=} | {exists=} | {fact=,is=},  -- optional
--   max_turns = number,                       -- optional, capped default
--   on_text   = function(chunk),              -- optional stream sink
--   runner    = function(text, sink) -> ...,  -- optional; defaults to a real turn
-- }
-- returns { met, turns, detail, budget }
function M.run(spec)
  assert(type(spec) == "table" and type(spec.task) == "string" and spec.task ~= "",
    "goal.run needs a task string")
  local max = math.max(1, math.floor(tonumber(spec.max_turns) or M.DEFAULT_MAX_TURNS))
  local runner = spec.runner or function(text, sink) return bog.api.run_turn(text, sink) end
  local check = spec.done and compile(spec.done) or nil
  local model_judged = (check == nil)

  local turns, met, detail = 0, false, nil

  -- A deterministic goal might already be satisfied before we spend a turn.
  if check then met, detail = check() end

  while not met and turns < max do
    turns = turns + 1
    local text = (turns == 1)
      and first_prompt(spec.task, model_judged)
      or continue_prompt(spec.task, detail, turns, max, model_judged)

    local saw_sentinel = false
    runner(text, function(chunk)
      if spec.on_text then spec.on_text(chunk) end
      if model_judged and chunk and chunk:find(M.SENTINEL, 1, true) then
        saw_sentinel = true
      end
    end)

    if check then
      met, detail = check()
    else
      met = saw_sentinel
    end
  end

  return { met = met, turns = turns, detail = detail, budget = max }
end

return M
