-- gold.re -- real regular expressions (POSIX ERE), backed by the C bindings in
-- src/lsys.c (sys.re_find / sys.re_gsub). This exists because Lua's built-in
-- patterns are much weaker than ERE -- no alternation, no {n,m}, no proper
-- groups -- which is a big part of why a model reaches for `python3 -c 'import
-- re'` instead of staying in-substrate. With this, the `lua` tool can do the
-- same regex work Python would, without leaving the process.
--
-- Flags string: "i" = case-insensitive, "m" = ^/$ match at line breaks.
-- Not available on Windows (POSIX regex is absent there); the calls surface the
-- C error rather than silently doing something weaker.
local M = {}

function M.available()
  return (select(1, sys.re_find("a", "a"))) ~= nil
end

-- find(s, pat[, flags[, init]]) -> start, end, cap1, ... | nil   (like string.find)
function M.find(s, pat, flags, init)
  return sys.re_find(s, pat, flags or "", init or 1)
end

-- test(s, pat[, flags]) -> boolean
function M.test(s, pat, flags)
  return (select(1, sys.re_find(s, pat, flags or "", 1))) ~= nil
end

-- match(s, pat[, flags]) -> the capture(s) if the pattern has groups, else the
-- whole matched string; nil if no match (mirrors string.match).
function M.match(s, pat, flags)
  local r = { sys.re_find(s, pat, flags or "", 1) }
  local a = r[1]
  if type(a) ~= "number" then return nil end
  if #r > 2 then return table.unpack(r, 3) end
  return s:sub(a, r[2])
end

-- gmatch(s, pat[, flags]) -> iterator yielding each match's capture(s) (or the
-- whole match when there are no groups), like string.gmatch.
function M.gmatch(s, pat, flags)
  flags = flags or ""
  local pos = 1
  local n = #s
  return function()
    while pos <= n + 1 do
      local r = { sys.re_find(s, pat, flags, pos) }
      local a = r[1]
      if type(a) ~= "number" then return nil end
      local e = r[2]
      pos = (e >= a) and (e + 1) or (a + 1) -- advance; empty match still moves
      if #r > 2 then return table.unpack(r, 3) end
      return s:sub(a, e)
    end
    return nil
  end
end

-- all(s, pat[, flags]) -> array of every match (whole match, or first capture
-- if the pattern has exactly one group). Convenience for the common "collect
-- every X" case.
function M.all(s, pat, flags)
  local out = {}
  for m in M.gmatch(s, pat, flags) do out[#out + 1] = m end
  return out
end

-- gsub(s, pat, repl[, flags[, max]]) -> result, count. `repl` supports \1..\9
-- and \0 (whole match) backreferences; max<0 (default) replaces all.
function M.gsub(s, pat, repl, flags, max)
  return sys.re_gsub(s, pat, repl, flags or "", max or -1)
end

return M
