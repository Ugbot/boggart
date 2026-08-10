-- gold.str -- string helpers.
local M = {}

function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function M.ltrim(s) return (s:gsub("^%s+", "")) end
function M.rtrim(s) return (s:gsub("%s+$", "")) end

function M.starts(s, prefix) return s:sub(1, #prefix) == prefix end
function M.ends(s, suffix) return suffix == "" or s:sub(-#suffix) == suffix end
function M.contains(s, sub) return s:find(sub, 1, true) ~= nil end

-- split(s)          -> split on runs of whitespace
-- split(s, sep)     -> split on the literal separator string
-- split(s, "")      -> split into individual characters
function M.split(s, sep)
  local out = {}
  if sep == nil then
    for w in s:gmatch("%S+") do out[#out + 1] = w end
    return out
  end
  if sep == "" then
    for c in s:gmatch(".") do out[#out + 1] = c end
    return out
  end
  local start = 1
  while true do
    local a, b = s:find(sep, start, true)
    if not a then out[#out + 1] = s:sub(start); break end
    out[#out + 1] = s:sub(start, a - 1)
    start = b + 1
  end
  return out
end

function M.lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

function M.indent(s, prefix)
  prefix = prefix or "  "
  return (s:gsub("[^\n]+", function(l) return prefix .. l end))
end

function M.dedent(s)
  -- remove the longest common leading-whitespace prefix from all non-blank lines
  local min
  for line in s:gmatch("[^\n]+") do
    if line:match("%S") then
      local n = #(line:match("^%s*"))
      if not min or n < min then min = n end
    end
  end
  if not min or min == 0 then return s end
  return (s:gsub("[^\n]*", function(l) return l:sub(min + 1) end))
end

return M
