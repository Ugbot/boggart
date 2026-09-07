-- transcript.lua -- RELOADING a conversation: re-baseline its history so it
-- is safe to continue under a possibly different model, wire, or process.
--
-- A transcript accumulates provenance-bound artifacts. The sharpest one is
-- thinking blocks: the API validates their signatures, and signatures do not
-- survive model generations, model SWAPS, compaction rewrites, or wire
-- adapters -- replaying one 400s with "Invalid signature in thinking block".
-- They are also never needed for continuation: only the live tool-use turn
-- must return its own blocks, and a reload never runs mid-turn.
--
-- So reload() is the one mechanism, and the call sites are the moments a
-- conversation's provenance changes:
--   * resuming from the store (bog.resume_session),
--   * swapping models mid-session (bog.set_model and the studio pickers),
--   * anything else that changes who will read the history next
--     (bog.reload_session(reason) is public precisely so a wire change or a
--     future migration can say so).
--
-- Future normalizations belong here too -- provider-specific fields, stale
-- cache markers -- one place, one contract: reload(messages) returns a
-- history any wire can replay.
local M = {}

-- Returns the reloaded message list and { thinking = n, dropped = n }:
-- thinking/redacted_thinking blocks removed, and assistant messages that
-- were nothing but thinking removed whole. Never mutates in place.
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
