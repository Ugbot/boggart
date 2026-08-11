-- fingerprint.lua -- everything about boggart's core that must not depend on
-- which front end loaded it.
--
-- boggart ships two programs: a terminal agent and a desktop application. They
-- are deliberately not two products -- the same engine with different focus,
-- the way an editor's CLI and its GUI are the same editor. That claim is easy
-- to make and easy to quietly break: someone registers a tool in one entry
-- point, or bumps a limit, or the GUI's bootstrap drifts from the CLI's, and
-- for a while nothing visibly fails. It just means an answer you get in the
-- terminal is not the answer you get in the window, which is the worst kind of
-- bug to chase because neither program is wrong on its own.
--
-- So the claim gets a test. This dumps the core as sorted key=value lines;
-- tools/parity.cmake runs it through both binaries and compares.
--
-- Printed as text rather than serialised because a human reading a failure
-- should be able to see what moved without a decoder.
local out = {}
local function put(k, v) out[#out + 1] = k .. "=" .. tostring(v) end

local function sorted_keys(t, filter)
  local ks = {}
  for k in pairs(t or {}) do
    if not filter or filter(k) then ks[#ks + 1] = k end
  end
  table.sort(ks)
  return table.concat(ks, ",")
end

-- ---- identity --------------------------------------------------------------
put("version", bog.version)

-- ---- the capability surface ------------------------------------------------
-- The API the harness exposes. A function appearing on one side and not the
-- other means the two front ends can do different things with the same model.
put("api", sorted_keys(bog.api))
put("store", sorted_keys(bog.store))
put("tools_api", sorted_keys(bog.tools))
put("memory", sorted_keys(bog.memory))
put("caps", sorted_keys(sys.caps()))
put("events", tostring(bog.events ~= nil))

-- ---- the tools the model is offered ----------------------------------------
-- The one place asymmetry is legitimate: the studio registers panel-drawing
-- tools that mean nothing without a window. parity.cmake knows about those by
-- name. Anything else differing is a bug, and a tool present in the CLI and
-- missing from the GUI is the dangerous direction.
local tools = {}
for _, t in ipairs(bog.tools.schemas()) do tools[#tools + 1] = t.name end
table.sort(tools)
put("tools", table.concat(tools, ","))

-- ---- behaviour that decides answers ---------------------------------------
-- If these differ, the same prompt gets a different reply depending on which
-- program you typed it into.
put("prompt_bytes", #bog.prompt.system())
put("model", bog.session.model)
put("compact_ratio", bog.api.COMPACT_RATIO)
put("context_limit", bog.api.context_limit(bog.session))
put("retry", string.format("%d/%d/%d", bog.api.RETRY.attempts,
  bog.api.RETRY.base_ms, bog.api.RETRY.max_ms))
put("tool_limits", string.format("%d/%d/%d", bog.tools.LIMITS.instructions,
  bog.tools.LIMITS.memory_kb, bog.tools.LIMITS.result_bytes))
put("scopes", sorted_keys(bog.tools.SCOPES))
put("endpoint_default", bog.api.endpoint())

-- ---- where it keeps things -------------------------------------------------
-- Paths are reported relative to the data directory rather than absolutely:
-- the two runs use different throwaway homes, and what must match is the
-- policy, not the temporary directory it landed in.
local home = tostring(bog.userdir)
local function rel(p)
  p = tostring(p or "")
  if p:sub(1, #home) == home then return "<data>" .. p:sub(#home + 1) end
  return "<elsewhere>"
end
put("db_path", rel(bog.userdir .. "/boggart.db"))
put("auth_path", rel((select(1, auth.path()))))
put("schema_version", (bog.db and bog.db:query(
  "SELECT value FROM meta WHERE key='schema_version'")[1] or {}).value)

table.sort(out)
io.write(table.concat(out, "\n"), "\n")
io.flush()
