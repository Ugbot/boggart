-- window.lua -- context-window arithmetic: when to compact, what to keep, and
-- how long a reply the next request may ask for.
--
-- Pure functions over numbers and message lists, so the rules can be tested
-- without a model. lua/api.lua owns the session state and the model calls and
-- asks this module for the numbers.
--
-- The rules follow the behaviour of the harnesses that hold up on long agent
-- tasks: compact when the conversation reaches the window minus a buffer (15%
-- of the window, at least 16k tokens), keep roughly the last 15k tokens of
-- conversation verbatim beside a summary of everything older, and never ask
-- for a reply longer than the room left in the window.
local json = require("json")

local M = {}

M.BUFFER = 0.15            -- compact this far below the window...
M.BUFFER_MIN = 16000       -- ...but never closer than this many tokens
-- A 16k buffer would leave nothing of a small local window (32k and below), so
-- the threshold never drops under half of it: compacting at every round is
-- worse than compacting a little late.
M.FLOOR = 0.5
M.KEEP = 15000             -- recent tokens kept verbatim through a compaction
-- On a small window 15k recent tokens plus a summary can be over the threshold
-- by themselves, and every round would compact again. Cap the kept tail at a
-- share of the threshold so a compacted conversation always has room to grow.
M.KEEP_SHARE = 0.25
M.REPLY_DEFAULT = 16000    -- longest reply when neither session nor catalog says
M.REPLY_MIN = 1024         -- never ask for less than this, however full
-- Estimates of messages the server has not measured yet are scaled up by this
-- much: chars/4 runs low on code and JSON, and the cost of guessing low is a
-- refused request rather than a slightly early compaction.
M.ESTIMATE_MARGIN = 1.15

local function block_chars(b)
  if type(b) ~= "table" then return #tostring(b or "") end
  if b.type == "text" then return #(b.text or "") end
  if b.type == "thinking" then return #(b.thinking or "") end
  if b.type == "tool_use" then
    local ok, s = pcall(json.encode, b.input or {})
    return #(b.name or "") + (ok and #s or 0)
  end
  if b.type == "tool_result" then
    local c = b.content
    if type(c) == "string" then return #c end
    if type(c) == "table" then
      local n = 0
      for _, x in ipairs(c) do n = n + block_chars(x) end
      return n
    end
    return 0
  end
  return 0
end

-- Estimated tokens in one message: characters / 4, the same crude rule the
-- rest of boggart uses when there is no measurement. Tool inputs count; they
-- are often the bulk of an assistant turn (a whole file written by `write`).
function M.tokens(m)
  if type(m) ~= "table" then return 0 end
  local chars = 0
  if type(m.content) == "string" then chars = #m.content
  elseif type(m.content) == "table" then
    for _, b in ipairs(m.content) do chars = chars + block_chars(b) end
  end
  return (chars + 3) // 4
end

-- Estimated tokens in messages[from..to].
function M.tokens_of(messages, from, to)
  local n = 0
  for i = from or 1, to or #messages do n = n + M.tokens(messages[i]) end
  return n
end

-- The token count at which a conversation is compacted, for a window of
-- `limit` tokens. `ratio` (a session's explicit compact_ratio) overrides the
-- buffer rule, so a test or a user can still say "compact at 30%".
function M.threshold(limit, ratio)
  if ratio then return limit * ratio end
  local buffer = math.max(limit * M.BUFFER, M.BUFFER_MIN)
  return math.max(limit - buffer, limit * M.FLOOR)
end

-- How many recent tokens a compaction keeps verbatim, given the threshold.
function M.keep_budget(threshold)
  return math.max(0, math.min(M.KEEP, math.floor(threshold * M.KEEP_SHARE)))
end

-- Where the kept tail of a conversation starts: the earliest index whose
-- messages[i..n] fit in `budget` tokens and which begins with an assistant
-- message. Returns #messages + 1 for "keep nothing".
--
-- Why an assistant message: the compacted conversation opens with a user
-- message (the summary), so a tail that starts with an assistant turn keeps the
-- roles alternating; and a tool_result always sits in the user message right
-- after the assistant message that called the tool, so cutting just before an
-- assistant message can never leave a result without its call, nor a call
-- without its result. Index 1 is never a start: something has to be summarised,
-- or a compaction of a short conversation would only add a summary to it.
function M.tail_start(messages, budget)
  local n = #messages
  local start, used = n + 1, 0
  for i = n, 2, -1 do
    used = used + M.tokens(messages[i])
    if used > budget then break end
    if messages[i].role == "assistant" then start = i end
  end
  return start
end

-- The reply limit for one request: the longest reply wanted, lowered to the
-- room left in a window of `limit` tokens when `used` are already taken, and
-- never below REPLY_MIN (unless the wanted length itself is smaller -- a
-- session that asks for 100 tokens gets 100).
function M.reply_tokens(want, limit, used)
  want = math.floor(want)
  if not (limit and used) then return want end
  local room = math.max(M.REPLY_MIN, math.floor(limit - used))
  return math.min(want, room)
end

return M
