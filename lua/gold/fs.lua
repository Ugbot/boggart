-- gold.fs -- filesystem helpers (thin, dependency-free wrappers over io + sys).
local M = {}

function M.read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a"); f:close()
  return data
end

function M.write(path, data)
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then sys.mkdir_p(parent) end
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data); f:close()
  return true
end

function M.append(path, data)
  local f, err = io.open(path, "ab")
  if not f then return nil, err end
  f:write(data); f:close()
  return true
end

function M.exists(path) return sys.stat(path) ~= nil end
function M.isdir(path) return sys.stat(path) == "dir" end
function M.isfile(path) return sys.stat(path) == "file" end
function M.mkdirp(path) return sys.mkdir_p(path) end

function M.basename(path) return (path:gsub("/+$", ""):match("[^/]+$")) or path end
function M.dirname(path)
  local d = path:gsub("/+$", ""):match("^(.*)/[^/]+$")
  return d ~= "" and d or (path:sub(1, 1) == "/" and "/" or ".")
end
function M.ext(path)
  return path:match("%.([%w_]+)$")
end

function M.join(...)
  local parts = { ... }
  local out = {}
  for _, p in ipairs(parts) do
    p = tostring(p)
    if p ~= "" then out[#out + 1] = (#out > 0) and p:gsub("^/+", "") or p end
  end
  return (table.concat(out, "/"):gsub("/+", "/"))
end

function M.list(dir)
  return sys.listdir(dir) or {}
end

-- Recursively walk a directory, calling fn(fullpath, kind) for each entry.
function M.walk(dir, fn)
  for _, name in ipairs(sys.listdir(dir) or {}) do
    local full = M.join(dir, name)
    local kind = sys.stat(full)
    fn(full, kind)
    if kind == "dir" then M.walk(full, fn) end
  end
end

-- Shell glob, C-backed (sys.glob -> POSIX glob). Returns a (possibly empty)
-- array of matching paths: gold.fs.glob("src/*.c"), gold.fs.glob("~/x/**")…
function M.glob(pattern)
  return sys.glob(pattern) or {}
end

-- Every file under `dir` whose basename matches the Lua/ERE test, recursively.
-- `match` may be a plain function(name)->bool, or a string treated as a POSIX
-- regex over the basename (via gold.re). Returns an array of full paths.
function M.find(dir, match)
  local test = match
  if type(match) == "string" then
    local re = require("gold.re")
    test = function(name) return re.test(name, match) end
  end
  local out = {}
  M.walk(dir, function(full, kind)
    if kind == "file" and (not test or test(M.basename(full))) then
      out[#out + 1] = full
    end
  end)
  return out
end

return M
