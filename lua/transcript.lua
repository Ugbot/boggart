-- transcript.lua -- reload a conversation: re-baseline its history so it is
-- safe to continue under a different model, wire, or process.
--
-- A transcript accumulates provenance-bound artifacts. Thinking blocks break
-- first: the API validates their signatures, and signatures do not survive
-- model generations, model swaps, compaction rewrites, or wire adapters.
-- Replaying one 400s with "Invalid signature in thinking block". They are
-- never needed for continuation: only the live tool-use turn must return its
-- own blocks, and a reload never runs mid-turn.
--
-- reload() is the one mechanism. The call sites are the moments provenance
-- changes: resuming from the store (bog.resume_session), swapping models
-- (bog.set_model and the studio pickers), and whatever else changes who reads
-- the history next (bog.reload_session(reason) is public for that). Future
-- normalizations, such as provider fields or stale cache markers, belong
-- here: one place, one contract, a history any wire can replay.
local M = {}

-- Returns the reloaded message list and { thinking = n, dropped = n }.
-- Thinking and redacted_thinking blocks are removed; an assistant message
-- that held nothing else is removed whole. Never mutates in place.
function M.reload(messages)
  local out, stats = {}, { thinking = 0, dropped = 0 }
  for _, m in ipairs(messages or {}) do
    if m.role == "assistant" and type(m.content) == "table" then
      local kept = {}
      for _, b in ipairs(m.content) do
        local t = type(b) == "table" and b.type
        if t == "thinking" or t == "redacted_thinking" then
          stats.thinking = stats.thinking + 1
        else
          kept[#kept + 1] = b
        end
      end
      if #kept > 0 then
        local copy = {}
        for k, v in pairs(m) do copy[k] = v end
        copy.content = kept
        out[#out + 1] = copy
      else
        stats.dropped = stats.dropped + 1
      end
    else
      out[#out + 1] = m
    end
  end
  return out, stats
end

return M
