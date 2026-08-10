-- gold.tbl -- table / list helpers.
local M = {}

function M.map(t, fn)
  local out = {}
  for i, v in ipairs(t) do out[i] = fn(v, i) end
  return out
end

function M.filter(t, pred)
  local out = {}
  for _, v in ipairs(t) do if pred(v) then out[#out + 1] = v end end
  return out
end

function M.reduce(t, fn, acc)
  for _, v in ipairs(t) do acc = fn(acc, v) end
  return acc
end

function M.each(t, fn)
  for i, v in ipairs(t) do fn(v, i) end
end

function M.keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  return out
end

function M.values(t)
  local out = {}
  for _, v in pairs(t) do out[#out + 1] = v end
  return out
end

function M.contains(t, x)
  for _, v in ipairs(t) do if v == x then return true end end
  return false
end

function M.index_of(t, x)
  for i, v in ipairs(t) do if v == x then return i end end
  return nil
end

function M.slice(t, i, j)
  local out = {}
  j = j or #t
  for k = i, j do out[#out + 1] = t[k] end
  return out
end

function M.reverse(t)
  local out = {}
  for i = #t, 1, -1 do out[#out + 1] = t[i] end
  return out
end

-- shallow merge: keys of b win over a
function M.merge(a, b)
  local out = {}
  for k, v in pairs(a) do out[k] = v end
  for k, v in pairs(b) do out[k] = v end
  return out
end

function M.deepcopy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, val in pairs(v) do out[M.deepcopy(k, seen)] = M.deepcopy(val, seen) end
  return out
end

-- sort_by(t, keyfn) -> new sorted array (stable-ish by key)
function M.sort_by(t, keyfn)
  local out = M.slice(t, 1)
  table.sort(out, function(a, b) return keyfn(a) < keyfn(b) end)
  return out
end

function M.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

return M
