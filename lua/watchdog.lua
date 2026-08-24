-- watchdog.lua -- catch an agent that is burning tokens WITHOUT acting (the
-- 151:1 think:output stall that produced the 11/14 chapter-run failure). A uv
-- timer periodically checks each live agent's progress; an agent that has taken
-- several model turns with no new tool call while its output keeps growing gets
-- ONE nudge via its inbox ("stop planning, act"). If it keeps stalling, Phase 0's
-- max_rounds / token_budget fail it and the exit contract reports the failure.
--
-- Cooperative, so it cannot catch a CPU-spin OUTSIDE run_bounded -- but a
-- token-burning stall streams (IO), so the loop keeps turning and this fires.
local M = {}
M.interval_ms = 8000   -- how often to look
M.stall_turns = 4      -- model turns with no new tool call before nudging
M.min_output  = 2000   -- ... and only once it has actually burned this many tokens
local timer

-- One sweep over the live agents (bog.thread.live, id -> rec). Public so a test
-- can drive it deterministically without the timer.
function M.tick()
  local live = bog.thread and bog.thread.live_recs
  if type(live) ~= "table" then return end
  for id, rec in pairs(live) do
    local s = rec.session or {}
    local turns = s._turns or 0
    local tools = s._tools or 0
    local out = (s.usage and s.usage.output) or 0
    local base_t = rec._wd_turns or 0
    local base_tool = rec._wd_tools or 0
    if tools > base_tool then
      -- A tool ran since last look: real progress. Reset the baseline + arming.
      rec._wd_turns, rec._wd_tools, rec._wd_nudged = turns, tools, false
    elseif (turns - base_t) >= M.stall_turns and out >= M.min_output and not rec._wd_nudged then
      -- Stalled: many turns, no new tool call, tokens climbing. Nudge once.
      rec._wd_nudged = true
      s.inbox = s.inbox or {}
      s.inbox[#s.inbox + 1] =
        "You have taken several turns without calling a tool. Stop planning and ACT "
        .. "now: call a tool to make progress, or say plainly that you are blocked and why."
      if bog.log then
        bog.log(string.format("watchdog: nudged stalled agent %d (%d turns, no tool call)",
          id, turns - base_t))
      end
      if bog.telemetry then
        bog.telemetry.decision({ run_id = rec.run_id or id, agent_id = id },
          { tool = "(watchdog)", decision = "nudge" })
      end
    end
  end
end

function M.start(interval)
  if timer then return end
  local ok, uv = pcall(require, "uv")
  if not ok or not uv then return end
  interval = interval or M.interval_ms
  timer = uv.new_timer()
  uv.timer_start(timer, interval, interval, function() pcall(M.tick) end)
end

function M.stop()
  if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
end

return M
