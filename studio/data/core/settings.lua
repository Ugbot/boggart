-- core/settings.lua -- the single write-path for the auth.* configuration.
--
-- welcomeview, settingsview and the command palette each used to call auth.set
-- directly with their own, divergent rules: only settingsview checked that an
-- endpoint carried a URL scheme, and none trimmed the API key -- so a key pasted
-- with a trailing newline was stored verbatim and then every request 401'd.
-- Routing every surface through here is one validate -> trim -> store ->
-- invalidate -> emit for all of them, so the same value means the same thing no
-- matter which screen typed it.

local settings = {}

local WIRES = { anthropic = true, openai = true, responses = true }

-- key -> normaliser. Returns (normalised_value) on success, or (nil, message).
-- These are pure and are unit-tested (tests/studio.lua), so the rules cannot
-- drift silently again.
settings.norm = {
  api_key = function(v)
    v = (v or ""):gsub("^%s+", ""):gsub("%s+$", "")   -- pasted keys carry newlines
    if v == "" then return nil, "empty API key" end
    return v
  end,
  base_url = function(v)
    v = (v or ""):gsub("%s+", "")                       -- a URL never has spaces
    if v == "" then return nil, "empty endpoint" end
    if not v:match("^%a[%w+%-.]*://") then
      return nil, ("%q has no scheme -- try http://%s"):format(v, v)
    end
    return (v:gsub("/+$", ""))                           -- one trailing-slash rule
  end,
  wire = function(v)
    v = (v or ""):lower():gsub("%s+", "")
    if not WIRES[v] then
      return nil, ("%q is not a wire -- type anthropic, openai or responses"):format(v)
    end
    return v
  end,
  model = function(v)
    v = (v or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then return nil, "empty model" end
    return v
  end,
}

-- Drop the resolved-auth cache and announce the change. Every set/clear ends
-- here, so a stale provider or base URL is never used after an edit.
function settings.invalidate()
  if bog and bog.api and bog.api.forget_auth then pcall(bog.api.forget_auth) end
  if bog and bog.events then pcall(bog.events.emit, "settings:changed", {}) end
end

-- settings.set(key, value) -> normalised value | nil, error_message
function settings.set(key, value)
  local n = settings.norm[key]
  if n then
    local v, err = n(value)
    if not v then return nil, err end
    value = v
  end
  local ok, err = auth.set(key, value)
  if not ok then return nil, err or ("could not store " .. tostring(key)) end
  settings.invalidate()
  return value
end

function settings.clear(key)
  auth.clear(key)
  settings.invalidate()
end

return settings
