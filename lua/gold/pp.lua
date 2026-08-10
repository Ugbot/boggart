-- gold.pp -- pretty-print / inspect Lua values (cycle-safe), for debugging.
local M = {}

local function keycmp(a, b)
  local ta, tb = type(a), type(b)
  if ta == tb then
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
  end
  return ta < tb
end

local function fmt(v, ind, seen)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
  if t ~= "table" then return "<" .. t .. ">" end
  if seen[v] then return "<cycle>" end
  seen[v] = true

  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, keycmp)
  if #keys == 0 then seen[v] = nil; return "{}" end

  local nind = ind .. "  "
  local parts = {}
  for _, k in ipairs(keys) do
    local ks
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
      ks = k
    else
      ks = "[" .. fmt(k, nind, seen) .. "]"
    end
    parts[#parts + 1] = nind .. ks .. " = " .. fmt(v[k], nind, seen)
  end
  seen[v] = nil
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
end

function M.pretty(v) return fmt(v, "", {}) end
function M.print(v) io.write(M.pretty(v), "\n") end

return M
