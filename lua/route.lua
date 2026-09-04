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

-- Is `prefix` a name we know, such that "prefix/rest" means "that endpoint,
-- this model"? The guard matters because OpenRouter's own model ids contain
-- slashes -- "anthropic/claude-opus-5" is a model, not a provider and a model --
-- so splitting unconditionally would send it to the wrong place.
local function known_prefix(name)
  if not name or name == "" then return false end
  local presets_t = presets.load() or {}
  if presets_t[name] then return true end
  local catalog = require "catalog"
  return catalog.provider(name) ~= nil
end

-- Resolve a spec to a complete route. Never errors: an unknown name is treated
-- as a model id on the current endpoint, because that is what it usually is,
-- and because failing a turn over a typo in a model name is worse than sending
-- it and letting the endpoint say it does not know that model.
--
-- Order (first match wins):
--   a table          as written
--   role:name / @name  the user's binding for that role
--   a preset name    user config outranks catalog knowledge
--   a catalog model  its provider's url, wire, auth, headers
--   prefix/rest      only when `prefix` is a known provider or preset
--   anything else    a bare model id on the current endpoint
function M.resolve(spec)
  local chain = M.resolve_chain(spec)
  return chain[1] or M.current()
end

-- The ordered candidates for a spec. Only a role produces more than one; every
-- other spec resolves to exactly one destination. Callers that can fall through
-- on failure (see api.lua) use this; callers that just need a destination use
-- resolve().
function M.resolve_chain(spec)
  local cur = M.current()
  if spec == nil or spec == "" then return { cur } end

  if type(spec) == "table" then
    -- a list of specs is a chain already (a role's binding, expanded)
    if #spec > 0 and type(spec[1]) == "string" then
      local out = {}
      for _, one in ipairs(spec) do
        for _, r in ipairs(M.resolve_chain(one)) do out[#out + 1] = r end
      end
      return #out > 0 and out or { cur }
    end
    return { {
      model = spec.model or cur.model,
      url   = spec.url   or cur.url,
      wire  = spec.wire  or cur.wire,
      auth  = spec.auth, key_slot = spec.key_slot, headers = spec.headers,
      name  = spec.name  or "inline",
    } }
  end

  spec = tostring(spec)

  -- a role: the user's binding, which may be a fallback chain
  local role_name = spec:match("^role:(.+)$") or spec:match("^@(.+)$")
  if role_name then
    local bound = require("catalog").role(role_name)
    if bound then
      local out = M.resolve_chain(bound)
      for _, r in ipairs(out) do r.role = role_name end
      return out
    end
    -- an unbound role falls through to the default rather than failing: an
    -- agent asking for "critic" on a machine that has never heard of one
    -- should still run.
    local dflt = require("catalog").role("default")
    if dflt then
      local out = M.resolve_chain(dflt)
      for _, r in ipairs(out) do r.role = role_name end
      return out
    end
    return { cur }
  end

  -- a preset: the user's own snapshot of an endpoint
  local presets_t = presets.load() or {}
  if presets_t[spec] then
    local p = presets_t[spec]
    return { { model = p.model or cur.model, url = p.url or cur.url,
               wire = p.wire or cur.wire, name = spec, effort = p.effort } }
  end

  -- a catalogued model: the whole destination comes with it
  local catalog = require "catalog"
  local dest = catalog.destination(spec)
  if dest then return { dest } end

  -- prefix/rest, only when the prefix is something we know
  local prefix, rest = spec:match("^([^/]+)/(.+)$")
  if prefix and rest and known_prefix(prefix) then
    if presets_t[prefix] then
      local p = presets_t[prefix]
      return { { model = rest, url = p.url or cur.url, wire = p.wire or cur.wire,
                 name = prefix } }
    end
    local p = catalog.provider(prefix)
    if p then
      return { { model = rest, url = p.url, wire = p.wire, auth = p.auth,
                 key_slot = p.key_slot or p.name, headers = p.headers,
                 provider = p.name, name = prefix } }
    end
  end

  -- not a preset: a bare model id on the endpoint already configured
  return { { model = spec, url = cur.url, wire = cur.wire, name = "model" } }
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
  -- A bound `utility` role first -- that is the name for "the model that does
  -- the bookkeeping" -- then the older cheap/fast presets, then whatever the
  -- session is on. Nothing is required: with none of them configured this is
  -- the current route and compaction happens exactly where it used to.
  local role = require("catalog").role("utility")
  if role then return M.resolve(role) end
  return M.alias("cheap") or M.alias("fast") or M.current()
end

return M
