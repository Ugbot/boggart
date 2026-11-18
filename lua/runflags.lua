-- runflags.lua -- session settings for an unattended run, from flags or the
-- environment.
--
-- Reasoning effort, the context window and the reply limit are session fields
-- that an interactive user sets with /effort and /context. A headless (stdin)
-- or one-shot (-p) run has no prompt to type them at, so a benchmark or a CI
-- job could not set them at all. These are the same three settings, read once
-- at start-up:
--
--   --effort <level>         BOGGART_EFFORT          minimal|low|medium|high|xhigh|max
--   --context-window <n>     BOGGART_CONTEXT_WINDOW  tokens, a positive integer
--   --max-output <n>         BOGGART_MAX_OUTPUT      tokens, a positive integer
--
-- A flag beats the environment. A bad value is an error, not a silent
-- default: a benchmark run that quietly ignored its settings would measure the
-- wrong thing and nobody would know.
local M = {}

-- The levels /effort accepts (lua/boot.lua). xhigh and max are Anthropic
-- levels; the OpenAI-shaped wires clamp them to high.
M.EFFORTS = { minimal = true, low = true, medium = true, high = true, xhigh = true, max = true }
M.EFFORT_LIST = "minimal|low|medium|high|xhigh|max"

M.SETTINGS = {
  { key = "effort",         flag = "--effort",         env = "BOGGART_EFFORT" },
  { key = "context_window", flag = "--context-window", env = "BOGGART_CONTEXT_WINDOW" },
  { key = "max_output",     flag = "--max-output",     env = "BOGGART_MAX_OUTPUT" },
}

local function positive_int(s)
  s = tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
  if not s:match("^%d+$") then return nil end
  local n = tonumber(s)
  if not n or n < 1 or n ~= math.floor(n) then return nil end
  return math.tointeger(n) or n
end

-- read(flags, getenv) -> settings | nil, err
--   flags   a table with any of effort / context_window / max_output as the
--           raw strings given on the command line (the `boggart` table)
--   getenv  os.getenv, or a stub in a test
-- settings is { effort?, context_limit?, max_tokens? }, using the session's
-- field names.
function M.read(flags, getenv)
  flags = flags or {}
  getenv = getenv or os.getenv
  local out = {}
  for _, s in ipairs(M.SETTINGS) do
    local raw, from = flags[s.key], s.flag
    if raw == nil or raw == "" then raw, from = getenv(s.env), s.env end
    if raw ~= nil and raw ~= "" then
      if s.key == "effort" then
        local v = tostring(raw):lower()
        if not M.EFFORTS[v] then
          return nil, string.format("%s: %q is not an effort level (%s)", from, raw, M.EFFORT_LIST)
        end
        out.effort = v
      else
        local n = positive_int(raw)
        if not n then
          return nil, string.format("%s: %q is not a positive whole number of tokens", from, raw)
        end
        if s.key == "context_window" then out.context_limit = n else out.max_tokens = n end
      end
    end
  end
  return out
end

-- Put the settings on a session. A context window smaller than the reply
-- limit cannot be served, so that combination is refused rather than sent.
function M.apply(sess, settings)
  if settings.context_limit and settings.max_tokens
     and settings.max_tokens >= settings.context_limit then
    return nil, string.format("--max-output (%d) must be smaller than --context-window (%d)",
      settings.max_tokens, settings.context_limit)
  end
  if settings.effort then sess.effort = settings.effort end
  if settings.context_limit then sess.context_limit = settings.context_limit end
  if settings.max_tokens then sess.max_tokens = settings.max_tokens end
  return sess
end

-- read + apply, for boot.lua: returns the session or nil, err.
function M.setup(sess, flags, getenv)
  local settings, err = M.read(flags, getenv)
  if not settings then return nil, err end
  return M.apply(sess, settings)
end

return M
