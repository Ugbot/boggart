-- loop.lua -- "do this task up to N times" for an agent, with escape hatches.
--
-- goal.run (the /react supervisor) loops turns until a goal is met, but a HUMAN
-- drives it via a slash command. This is the same shape exposed so the MODEL can
-- drive it, mid-turn, as the `loop` tool: an agent can repeat its own work with
-- one call instead of hand-rolling a loop.
--
-- Each iteration runs on its OWN sub-session, never the caller's, so nesting a
-- loop inside a turn does not recurse into that turn's transcript or the model's
-- global state:
--   fresh = false (default): one sub-session carried across iterations (memory).
--   fresh = true           : a fresh sub-session each iteration (clean context).
--
-- Escape hatches (all optional; `times` is always the hard cap):
--   until          a done-check ({shell=}/{exists=}/{fact=,is=}) -- stop when it passes.
--                  With no `until`, the agent ends the loop itself by emitting a
--                  done sentinel (model-judged).
--   stop_on_error  stop at the first failing iteration (default true).
--   max_failures   tolerate up to K failures before bailing (overrides stop_on_error).
--   effort/token_budget  bound each iteration's reasoning / output.
local goal = require "goal"

local M = {}
M.DEFAULT_TIMES = 5
M.HARD_MAX = 50            -- an absolute ceiling no `times` may exceed

local function sub_session(model, effort, token_budget)
  return {
    model = model or (bog.session and bog.session.model),
    messages = {},
    max_tokens = 16000,
    effort = effort,
    token_budget = token_budget,
  }
end

-- spec = { task, times, until_, fresh, stop_on_error, max_failures,
--          effort, token_budget, on_text }
-- returns { iterations, times, met, failures, detail, summaries }
function M.run(spec)
  assert(type(spec) == "table" and type(spec.task) == "string" and spec.task ~= "",
    "loop.run needs a task string")
  local times = math.floor(tonumber(spec.times) or M.DEFAULT_TIMES)
  times = math.max(1, math.min(M.HARD_MAX, times))

  local check = spec.until_ ~= nil and goal.compile(spec.until_) or nil
  local model_judged = (check == nil)

  -- Failures allowed before bailing: max_failures wins; else stop_on_error
  -- (default true) means zero; stop_on_error=false means unlimited.
  local allowed
  if spec.max_failures ~= nil then allowed = math.max(0, math.floor(tonumber(spec.max_failures) or 0))
  elseif spec.stop_on_error == false then allowed = math.huge
  else allowed = 0 end

  local shared = (not spec.fresh)
    and sub_session(spec.model, spec.effort, spec.token_budget) or nil

  local iters, failures, met, detail = 0, 0, false, nil
  local summaries = {}

  -- A deterministic `until` may already hold before we spend an iteration.
  if check then met, detail = check() end

  -- Keep an iteration from auto-delegating to a specialist -- the loop is
  -- already the orchestration, and dispatch here would recurse.
  local dsave = bog.dispatch and bog.dispatch.depth
  if bog.dispatch then bog.dispatch.depth = (dsave or 0) + 1 end

  -- One iteration: run `prompt` on `sess`, returning ok:bool, text:string. The
  -- default drives a real sub-agent turn; tests inject spec.iterate to exercise
  -- the control flow without a model.
  local iterate = spec.iterate or function(prompt, sess)
    local out = {}
    local ok, err = pcall(bog.api.run_on, sess, prompt, function(chunk)
      out[#out + 1] = chunk
      if spec.on_text then spec.on_text(chunk) end
    end, { effort = spec.effort, token_budget = spec.token_budget })
    return ok, ok and table.concat(out) or tostring(err)
  end

  while not met and iters < times do
    iters = iters + 1
    local isess = spec.fresh and sub_session(spec.model, spec.effort, spec.token_budget) or shared
    local note = model_judged
      and ("\n\nWhen the whole task is complete and no more iterations are needed, end your "
           .. "reply with " .. goal.SENTINEL .. " on its own line -- not before.") or ""
    local prompt = string.format("Iteration %d of %d.\n\n%s%s", iters, times, spec.task, note)

    local ok, text = iterate(prompt, isess)
    summaries[iters] = { ok = ok, text = text }
    if not ok then
      failures = failures + 1
      if failures > allowed then
        detail = string.format("stopped after %d failure(s) (%s allowed)",
          failures, allowed == math.huge and "unlimited" or tostring(allowed))
        break
      end
    end

    if check then met, detail = check()
    elseif ok and text and text:find(goal.SENTINEL, 1, true) then
      met, detail = true, "the agent reported the task complete"
    end
  end

  if bog.dispatch then bog.dispatch.depth = dsave end

  return {
    iterations = iters, times = times, met = met, failures = failures,
    detail = detail, summaries = summaries,
  }
end

return M
