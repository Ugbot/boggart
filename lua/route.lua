-- route.lua -- which model, on which endpoint, over which wire.
--
-- `model` was per-session but the endpoint, the wire and the key were global,
-- so "use a different model" only worked if the other model lived on the same
-- server behind the same protocol. A fleet could not put a cheap local critic
-- next to a strong cloud coder, which is the obvious thing to want the moment
-- you have more than one agent.
--
-- A ROUTE is the whole destination -- { model, url, wire } -- resolved per
-- request instead of read from global state. Everything else stays where it
-- was: presets already bundle exactly this trio under a name, and the key still
-- lives in C, matched to the endpoint the request is going to (see
-- boggart_auth_header_for in src/lauth.c). Lua names a destination; C picks the
-- credential. The secret never crosses.
--
-- A spec can be:
--   nil                  the configured endpoint -- unchanged behaviour
--   "claude-opus-5"      that model, on the current endpoint/wire
--   "ds4"                a preset by name: its url, wire AND model
--   "ds4/deepseek-v4"    that preset's endpoint, overriding its model
--   { model=, url=, wire= }   spelled out
--
-- The preset-name form is what makes this usable in a spawn: `spawn{ model =
-- "ds4" }` is a whole provider switch for one child, in one word.
local M = {}

local presets = require "presets"

-- The configured destination: what every request used before routes existed.
function M.current()
  local api = require "api"
  return {
    model = (bog.session and bog.session.model) or auth.model(),
    url   = auth.base_url(),
    wire  = api.wire(),
    name  = "current",
  }
end

-- Resolve a spec to a complete route. Never errors: an unknown name is treated
-- as a model id on the current endpoint, because that is what it usually is,
-- and because failing a turn over a typo in a model name is worse than sending
-- it and letting the endpoint say it does not know that model.
function M.resolve(spec)
  local cur = M.current()
  if spec == nil or spec == "" then return cur end

  if type(spec) == "table" then
    return {
      model = spec.model or cur.model,
      url   = spec.url   or cur.url,
      wire  = spec.wire  or cur.wire,
      name  = spec.name  or "inline",
    }
  end

  spec = tostring(spec)
  local name, model_override = spec:match("^([^/]+)/(.+)$")
  local key = name or spec
  local table_of = presets.load() or {}
  local p = table_of[key]
  if p then
    return {
      model = model_override or p.model or cur.model,
      url   = p.url or cur.url,
      wire  = p.wire or cur.wire,
      name  = key,
      effort = p.effort,
    }
  end

  -- not a preset: a bare model id on the endpoint already configured
  return { model = spec, url = cur.url, wire = cur.wire, name = "model" }
end

-- Every destination that can be named, for a picker or `/model`.
function M.list()
  local names, t = presets.list()
  local out = {}
  for _, n in ipairs(names) do
    local p = t[n] or {}
    out[#out + 1] = { name = n, model = p.model, url = p.url, wire = p.wire }
  end
  return out
end

-- A one-line rendering, for a status bar or a log line: the model, and where it
-- is, when that is not the default.
function M.describe(r)
  if not r then return "?" end
  local where = r.url and r.url:match("^https?://([^/]+)") or nil
  if not where then return tostring(r.model) end
  return string.format("%s @ %s", tostring(r.model), where)
end

-- ---------------------------------------------------------------------------
-- Named roles: the cheap seat and the good seat
-- ---------------------------------------------------------------------------
--
-- Most per-model routing in practice is not "this exact id" but "something
-- cheap for the mechanical part". Two optional aliases give that a name without
-- inventing a model registry: set a preset called `cheap` (or `fast`) and
-- compaction, summarisation and other bookkeeping turns can use it, while the
-- work itself stays on whatever the session is. Absent, everything falls back
-- to the current route -- so this costs nothing until someone opts in.
M.ALIASES = { cheap = true, fast = true, strong = true }

function M.alias(name)
  local t = presets.load() or {}
  if t[name] then return M.resolve(name) end
  return nil
end

-- The route a bookkeeping turn should use: `cheap`, else `fast`, else current.
function M.utility()
  return M.alias("cheap") or M.alias("fast") or M.current()
end

return M
