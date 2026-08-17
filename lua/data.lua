-- data.lua -- a tiny JSON key/value store under ~/.boggart/data/, for sharing
-- structured state ACROSS the tool sandbox boundary.
--
-- The problem it solves: a skill's `instructions` function runs with full access
-- (it can require modules, compute rules), but a skill's provided-tool BODY runs
-- sandboxed (no require/load/io). So the natural pattern -- the rules live once,
-- the writer's instructions and a checker tool both read them -- needs a channel
-- the sandbox can use. `data` is that channel: the instructions call
-- `data.put("style", {...})`, the sandboxed checker calls `data.get("style")`.
-- Both sides use the same helper; the state has one home.
--
-- `data` is exposed in the tool sandbox env (lua/tools.lua) AND is a normal
-- require()-able module for full-context callers.
local json = require("json")

local M = {}

local function base()
  local home = os.getenv("HOME") or "."
  local d = home .. "/.boggart/data"
  if sys and sys.mkdir_p then pcall(sys.mkdir_p, d) end
  return d
end

-- Names are filenames, so keep them to a safe, predictable charset.
function M.path(name)
  return base() .. "/" .. (tostring(name):gsub("[^%w%._%-]", "_")) .. ".json"
end

-- put(name, value) -> true|false. Stores any JSON-able value.
function M.put(name, value)
  local f = io.open(M.path(name), "w")
  if not f then return false end
  f:write(json.encode(value)); f:close()
  return true
end

-- get(name[, default]) -> the stored value, or default (nil) if absent/corrupt.
function M.get(name, default)
  local f = io.open(M.path(name), "r")
  if not f then return default end
  local s = f:read("*a"); f:close()
  local ok, v = pcall(json.decode, s)
  if not ok then return default end
  return v
end

return M
