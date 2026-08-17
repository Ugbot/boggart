-- presets.lua -- named endpoint presets.
--
-- boggart keeps ONE active endpoint (url + wire + model) in the credential
-- store, so hopping between two servers means retyping the trio each time. A
-- preset bundles those three under a name, so `/endpoint gpt-oss` <-> `/endpoint
-- ds4` (or `/model <name>`) is one command. The API KEY is deliberately NOT part
-- of a preset -- keys live per-provider in the C store, matched by endpoint, and
-- must never land in a plain JSON file the model could read. Presets are stored
-- as JSON next to the credential store (same directory, same owner-only intent).
local json = require("json")

local M = {}

local function path()
  local p = auth.path()                        -- .../boggart/<authfile>
  local dir = p:match("^(.*)/[^/]*$") or "."
  return dir .. "/presets.json"
end
M.path = path

function M.load()
  local f = io.open(path(), "r")
  if not f then return {} end
  local data = f:read("*a"); f:close()
  local ok, t = pcall(json.decode, data)
  return (ok and type(t) == "table") and t or {}
end

function M.save(t)
  local f = io.open(path(), "w")
  if not f then return false end
  f:write(json.encode(t)); f:close()
  return true
end

-- Names, sorted, plus the raw table so callers can render details in one read.
function M.list()
  local t, names = M.load(), {}
  for k in pairs(t) do names[#names + 1] = k end
  table.sort(names)
  return names, t
end

-- Snapshot the CURRENT endpoint config under `name`.
function M.put(name)
  local t = M.load()
  t[name] = { url = auth.base_url(), wire = auth.wire() or "anthropic", model = auth.model(),
              effort = bog.session and bog.session.effort or nil }
  M.save(t)
  return t[name]
end

-- Define a preset explicitly (used to seed known endpoints).
function M.set(name, spec)
  local t = M.load()
  t[name] = { url = spec.url, wire = spec.wire or "anthropic", model = spec.model, effort = spec.effort }
  M.save(t)
  return t[name]
end

function M.remove(name)
  local t = M.load()
  if t[name] == nil then return false end
  t[name] = nil; M.save(t)
  return true
end

-- Apply a preset to the live credential store. Empty strings clear a field (an
-- absent url means the default Anthropic cloud), so applying a preset fully
-- defines the endpoint rather than leaving a stale value from the last one.
function M.apply(name)
  local p = M.load()[name]
  if not p then return false end
  auth.set("base_url", p.url or "")
  auth.set("wire", p.wire or "anthropic")
  auth.set("model", p.model or "")
  -- Set the model on the session a turn actually runs on (the coordinator in the
  -- cTUI/swarm, else bog.session) -- not just bog.session -- so the request body
  -- carries the switched model and not the coordinator's stale one.
  if p.model and p.model ~= "" then
    if bog.set_model then bog.set_model(p.model)
    elseif bog.session then bog.session.model = p.model end
  end
  local active = bog.active_session and bog.active_session() or bog.session
  if active then active.effort = p.effort end          -- carry the preset's effort (or clear it)
  if bog.session then bog.session.effort = p.effort end
  bog.api.forget_auth()
  return p
end

return M
