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
--
-- BOGGART_TOOLS (environment only) names a tool profile, a narrower set of
-- tools to offer. It is checked here for the same reason: an unknown name used
-- to be logged and ignored, so a run that asked for a narrow set was offered
-- every tool.
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

-- Values of BOGGART_TOOLS that mean "no profile": every tool is offered.
M.TOOLS_OFF = { full = true, all = true, default = true, none = true }

-- The tool profiles BOGGART_TOOLS may name, as a set. The tools module's own
-- list when it has one (tools.PROFILES), so the two cannot disagree; otherwise
-- the profiles this release documents.
function M.tool_profiles()
  local ok, tools = pcall(require, "tools")
  if ok and type(tools) == "table" and type(tools.PROFILES) == "table" then
    local set = {}
    for name in pairs(tools.PROFILES) do set[name] = true end
    return set
  end
  return { coding = true }
end

local function check_tools(raw)
  if raw == nil or raw == "" or M.TOOLS_OFF[raw] or M.tool_profiles()[raw] then return true end
  local names = {}
  for name in pairs(M.tool_profiles()) do names[#names + 1] = name end
  table.sort(names)
  return nil, string.format("BOGGART_TOOLS: %q is not a tool profile (%s, or full for every tool)",
    raw, table.concat(names, "|"))
end

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
-- field names. sources, the second result, names where each one came from
-- (the flag or the variable), keyed the same way, for messages about them.
function M.read(flags, getenv)
  flags = flags or {}
  getenv = getenv or os.getenv
  local out, sources = {}, {}
  local okt, terr = check_tools(getenv("BOGGART_TOOLS"))
  if not okt then return nil, terr end
  for _, s in ipairs(M.SETTINGS) do
    local raw, from = flags[s.key], s.flag
    if raw == nil or raw == "" then raw, from = getenv(s.env), s.env end
    if raw ~= nil and raw ~= "" then
      if s.key == "effort" then
        local v = tostring(raw):lower()
        if not M.EFFORTS[v] then
          return nil, string.format("%s: %q is not an effort level (%s)", from, raw, M.EFFORT_LIST)
        end
        out.effort, sources.effort = v, from
      else
        local n = positive_int(raw)
        if not n then
          return nil, string.format("%s: %q is not a positive whole number of tokens", from, raw)
        end
        local field = (s.key == "context_window") and "context_limit" or "max_tokens"
        out[field], sources[field] = n, from
      end
    end
  end
  return out, sources
end

-- Put the settings on a session. A context window smaller than the reply
-- limit cannot be served, so that combination is refused rather than sent.
-- The refusal names where each value came from (`sources`, from read; the
-- flags when not given): someone who set only BOGGART_MAX_OUTPUT and
-- BOGGART_CONTEXT_WINDOW was told about flags they never passed.
function M.apply(sess, settings, sources)
  sources = sources or {}
  if settings.context_limit and settings.max_tokens
     and settings.max_tokens >= settings.context_limit then
    return nil, string.format("%s (%d) must be smaller than %s (%d)",
      sources.max_tokens or "--max-output", settings.max_tokens,
      sources.context_limit or "--context-window", settings.context_limit)
  end
  if settings.effort then sess.effort = settings.effort end
  if settings.context_limit then sess.context_limit = settings.context_limit end
  if settings.max_tokens then sess.max_tokens = settings.max_tokens end
  return sess
end

-- read + apply, for boot.lua: returns the session or nil, err.
function M.setup(sess, flags, getenv)
  local settings, sources = M.read(flags, getenv)
  if not settings then return nil, sources end
  return M.apply(sess, settings, sources)
end

return M
