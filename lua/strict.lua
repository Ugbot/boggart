-- strict.lua -- turn typos in globals into loud errors at the exact line.
-- Adapted from rxi/lite (MIT, (c) 2020 rxi). Especially valuable here because
-- the most common failure in model-written Lua is a misspelled global silently
-- reading nil and blowing up three functions later.
local strict = {}
strict.defined = {}

function strict.__newindex(t, k, v)
  error("cannot set undefined global: " .. tostring(k), 2)
end

function strict.__index(t, k)
  if not strict.defined[k] then
    error("cannot get undefined global: " .. tostring(k), 2)
  end
end

-- Declare/assign globals explicitly:  global{ name = value, ... }
function global(t)
  for k, v in pairs(t) do
    strict.defined[k] = true
    rawset(_G, k, v)
  end
end

-- Run fn with the global guard lifted, then restore it no matter what.
--
-- This exists for *vendored* Lua that we do not want to fork. ltui's module
-- idiom is `local view = view or object()` in all 32 of its modules -- a read
-- of an undefined global, which strict rightly rejects. Patching every file
-- would make re-vendoring ltui painful, and the guard is here to catch typos
-- in model-written Lua, not to police trusted third-party code.
--
-- Keep the window as small as possible: require("ltui") pulls in the whole
-- tree eagerly, so one call covers it.
function strict.without(fn, ...)
  local mt = getmetatable(_G)
  setmetatable(_G, nil)
  local ok, res = pcall(fn, ...)
  setmetatable(_G, mt)
  if not ok then error(res, 0) end
  return res
end

-- Mark already-existing globals (C-pushed libs, stdlib) as defined so reads of
-- them pass, then lock the table.
function strict.enable()
  for k in pairs(_G) do strict.defined[k] = true end
  strict.defined.global = true
  setmetatable(_G, strict)
end

return strict
