local strict = {}
strict.defined = {}


-- Used to define a global variable.
--
-- boggart: renamed from `global`, which Lua 5.5 made a reserved word. (The
-- same rename happened to boggart's own lua/strict.lua, which was adapted from
-- this file -- so the incompatibility landed in both copies at once.)
-- LUA_COMPAT_GLOBAL is deliberately off in our vendored Lua, so a missed call
-- site is a load error now rather than a surprise when the option is removed.
function declare(t)
  for k, v in pairs(t) do
    strict.defined[k] = true
    rawset(_G, k, v)
  end
end


function strict.__newindex(t, k, v)
  error("cannot set undefined variable: " .. k, 2)
end


function strict.__index(t, k)
  if not strict.defined[k] then
    error("cannot get undefined variable: " .. k, 2)
  end
end


setmetatable(_G, strict)
