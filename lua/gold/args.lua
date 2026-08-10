-- gold.args -- tokenize shell-ish strings and parse simple flags. Handy for
-- tools that accept a raw command line in one string argument.
local M = {}

-- Split a string into argv, honoring single/double quotes and backslash escapes.
function M.tokenize(s)
  local out, cur, i, n, has = {}, {}, 1, #s, false
  local function flush()
    if has then out[#out + 1] = table.concat(cur); cur = {}; has = false end
  end
  while i <= n do
    local c = s:sub(i, i)
    if c == "'" then
      has = true
      local j = s:find("'", i + 1, true) or (n + 1)
      cur[#cur + 1] = s:sub(i + 1, j - 1); i = j + 1
    elseif c == '"' then
      has = true
      i = i + 1
      while i <= n do
        local d = s:sub(i, i)
        if d == '"' then i = i + 1; break end
        if d == "\\" and i < n then cur[#cur + 1] = s:sub(i + 1, i + 1); i = i + 2
        else cur[#cur + 1] = d; i = i + 1 end
      end
    elseif c:match("%s") then
      flush(); i = i + 1
    elseif c == "\\" and i < n then
      has = true; cur[#cur + 1] = s:sub(i + 1, i + 1); i = i + 2
    else
      has = true; cur[#cur + 1] = c; i = i + 1
    end
  end
  flush()
  return out
end

-- Parse an argv array into { flags = {name=value|true}, positional = {...} }.
-- Supports --name, --name=value, --name value, and -x short flags (boolean).
function M.parse(argv)
  local flags, pos, i = {}, {}, 1
  while i <= #argv do
    local a = argv[i]
    local k, v = a:match("^%-%-([%w%-_]+)=(.*)$")
    if k then
      flags[k] = v
    elseif a:match("^%-%-[%w%-_]+$") then
      local name = a:sub(3)
      local nxt = argv[i + 1]
      if nxt and nxt:sub(1, 1) ~= "-" then flags[name] = nxt; i = i + 1
      else flags[name] = true end
    elseif a:match("^%-[%w]+$") then
      for ch in a:sub(2):gmatch(".") do flags[ch] = true end
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return { flags = flags, positional = pos }
end

return M
