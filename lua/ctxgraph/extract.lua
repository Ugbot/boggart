-- ctxgraph/extract.lua -- entities and checkable claims from one tool call.
--
-- Rules, not a model: the same call always yields the same entities, which is
-- what keeps stubs byte-stable and graph compaction free of model calls.
--
--   read/write/edit path      -> file entity (write/edit add a version)
--   bash command              -> command entity, plus per segment:
--     pip/apt/npm install X   -> package entity, claim installed|install_failed
--     a test runner           -> test entity, claim passed|failed
--   a failed call             -> error entity keyed by its first error line
--   spawn                     -> a thread (the caller makes the node)
--
-- Claims here are ones the harness observed itself (an exit status), so they
-- start `reproduced` (assumption 17). Where an exit status cannot be pinned on
-- one segment of a compound command (`a && b` failed: which one?), no claim
-- is made rather than a guessed one.
local M = {}

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

function M.sha(s)
  local okc, c = pcall(require, "hash_c")
  if okc and c and c.sha256 then return c.sha256(s) end
  return require("workflow").hash(s)
end
local function short(s) return M.sha(s):sub(1, 12) end

-- A workspace-relative path: `root` (the project root or cwd) is stripped, as
-- are `./` and doubled slashes, so the same file is one entity however it was
-- spelled.
function M.relpath(path, root)
  local p = trim(path):gsub("//+", "/")
  if root and root ~= "" then
    local r = root:gsub("/+$", "")
    if p == r then return "." end
    if p:sub(1, #r + 1) == r .. "/" then p = p:sub(#r + 2) end
  end
  p = p:gsub("^%./", "")
  return p
end

-- "[exit=N]" / "[exit=N TIMED OUT]" at the head of a bash result.
function M.exit_code(result)
  local code, rest = tostring(result or ""):match("^%[exit=(%-?%d+)([^%]]*)%]")
  if not code then return nil end
  return tonumber(code), rest:find("TIMED OUT", 1, true) ~= nil
end

-- The line that names a failure: a Python-style "XError: msg" (the last one,
-- which is the raised error, not a frame), else the first line mentioning an
-- error, else the first non-empty line after the status. Capped, so a
-- minified one-line dump cannot become a 50 KB key.
function M.error_line(result)
  local text = tostring(result or "")
  text = text:gsub("^Tool error:%s*", ""):gsub("^%[exit=[^%]]*%]%s*", "")
  local last_typed, first_err, first_line
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local l = trim(line)
    if l ~= "" then
      first_line = first_line or l
      if l:match("^[%w_%.]*Error:") or l:match("^[%w_%.]*Exception:") or l:match("^[%w_%.]+Error$") then
        last_typed = l
      elseif not first_err and (l:lower():find("error", 1, true) or l:find("FAILED", 1, true)) then
        first_err = l
      end
    end
    if line:find("^%[output truncated:") then break end
  end
  local l = last_typed or first_err or first_line
  if not l then return nil end
  if #l > 200 then l = l:sub(1, 200) end
  return l
end

-- Shell words of one segment, quotes stripped (no expansion: this is
-- classification, not execution).
local function words(seg)
  local out = {}
  for word in seg:gmatch("%S+") do
    out[#out + 1] = (word:gsub("^['\"]", ""):gsub("['\"]$", ""))
  end
  -- leading env assignments and wrappers say nothing about what runs
  while out[1] and (out[1]:match("^[%w_]+=") or out[1] == "sudo" or out[1] == "env"
                    or out[1] == "time" or out[1] == "nohup" or out[1] == "exec") do
    table.remove(out, 1)
  end
  return out
end

-- Split on && || ; | outside quotes. `op` records what joined each segment to
-- the previous one.
function M.segments(cmd)
  local segs, cur, q, i, op = {}, {}, nil, 1, nil
  local s = tostring(cmd or "")
  local function push(nextop)
    local t = trim(table.concat(cur))
    if t ~= "" then segs[#segs + 1] = { text = t, op = op } end
    cur, op = {}, nextop
  end
  while i <= #s do
    local ch = s:sub(i, i)
    local two = s:sub(i, i + 1)
    if q then
      if ch == q then q = nil end
      cur[#cur + 1] = ch
      i = i + 1
    elseif ch == "'" or ch == '"' then
      q = ch; cur[#cur + 1] = ch; i = i + 1
    elseif two == "&&" or two == "||" then
      push(two); i = i + 2
    elseif ch == ";" or ch == "\n" or ch == "|" then
      push(ch == "|" and "|" or ";"); i = i + 1
    else
      cur[#cur + 1] = ch; i = i + 1
    end
  end
  push(nil)
  return segs
end

-- flags of pip/npm/apt that take a value, so the value is not a package
local VALUE_FLAGS = { ["-r"] = "file", ["--requirement"] = "file", ["-c"] = "file", ["--constraint"] = "file",
  ["-i"] = true, ["--index-url"] = true, ["--extra-index-url"] = true, ["-t"] = true, ["--target"] = true,
  ["--prefix"] = true, ["-f"] = true, ["--find-links"] = true, ["-e"] = "file", ["--editable"] = "file",
  ["--registry"] = true, ["-o"] = true }

-- Packages an install segment names: { manager, name, version? }, plus files
-- it reads (pip -r requirements.txt).
local function installs(w)
  local mgr, at
  local first = w[1] or ""
  if first:match("^pip[%d%.]*$") and w[2] == "install" then mgr, at = "pip", 3
  elseif first:match("^python[%d%.]*$") and w[2] == "-m" and w[3] == "pip" and w[4] == "install" then mgr, at = "pip", 5
  elseif first == "uv" and w[2] == "pip" and w[3] == "install" then mgr, at = "pip", 4
  elseif (first == "apt-get" or first == "apt") and w[2] == "install" then mgr, at = "apt", 3
  elseif first == "npm" and (w[2] == "install" or w[2] == "i" or w[2] == "add") then mgr, at = "npm", 3
  end
  if not mgr then return nil end
  local pkgs, files, i = {}, {}, at
  while i <= #w do
    local t = w[i]
    local f = VALUE_FLAGS[t]
    if f then
      if f == "file" and w[i + 1] then files[#files + 1] = w[i + 1] end
      i = i + 2
    elseif t:sub(1, 1) == "-" or t:find("^[<>]") then
      i = i + 1
    else
      local name, ver
      if mgr == "npm" then
        name, ver = t:match("^(@?[^@]+)@(.+)$")
        name = name or t
      elseif mgr == "apt" then
        name, ver = t:match("^([^=]+)=(.+)$")
        name = name or t
      else
        name = t:match("^([%w%._%-]+)")
        ver = t:match("==([%w%._%-%+]+)")
      end
      if name and name ~= "" and not name:find("/", 1, true) and not name:find("%.txt$") then
        pkgs[#pkgs + 1] = { manager = mgr, name = name:lower(), version = ver }
      end
      i = i + 1
    end
  end
  return pkgs, files
end

-- Is this segment a test run? -> test id (the target, else the runner).
local function test_of(w)
  local first = w[1] or ""
  local runner, at
  if first == "pytest" or first == "py.test" then runner, at = "pytest", 2
  elseif first:match("^python[%d%.]*$") and w[2] == "-m" and (w[3] == "pytest" or w[3] == "unittest") then runner, at = w[3], 4
  elseif first == "npm" and (w[2] == "test" or (w[2] == "run" and w[3] == "test")) then return "npm test"
  elseif first == "cargo" and w[2] == "test" then runner, at = "cargo test", 3
  elseif first == "go" and w[2] == "test" then runner, at = "go test", 3
  elseif first == "make" and (w[2] == "test" or w[2] == "check") then return "make " .. w[2]
  elseif first == "ctest" or first == "tox" then return first
  else return nil end
  for i = at, #w do
    local t = w[i]
    if t:sub(1, 1) ~= "-" and not t:find("=", 1, true) then return runner .. " " .. t end
  end
  return runner
end

local TRIVIAL = { cd = true, export = true, source = true, ["."] = true, set = true, echo = true, ["true"] = true }

-- Everything one bash call says. -> { entities = {...}, claims = {...} }
-- entity: { type, id, title, edge, attrs }; claim: { subject, predicate, title }
local function bash(input, result, root)
  local out = { entities = {}, claims = {} }
  local cmd = trim(input.command):gsub("%s+", " ")
  if cmd == "" then return out end
  local code, timed_out = M.exit_code(result)
  local cmd_id = "cmd/" .. short(cmd)
  out.entities[#out.entities + 1] = { type = "command", id = cmd_id, title = cmd, edge = "runs",
    attrs = { command = cmd, exit = code, timed_out = timed_out or nil } }
  if code then
    out.claims[#out.claims + 1] = { subject = cmd_id, predicate = "exit=" .. code,
      title = "`" .. (#cmd > 60 and cmd:sub(1, 57) .. "..." or cmd) .. "` exits " .. code }
  end
  local segs = M.segments(cmd)
  local nontrivial = 0
  for _, s in ipairs(segs) do
    local w = words(s.text)
    if w[1] and not TRIVIAL[w[1]] then nontrivial = nontrivial + 1 end
  end
  local all_and = true
  for i = 2, #segs do if segs[i].op ~= "&&" then all_and = false end end
  -- Can this segment's outcome be read off the command's exit status? Yes when
  -- the whole chain succeeded under && (every segment ran and succeeded), or
  -- when it is the only segment that does anything.
  local function outcome_known(ok)
    if code == nil then return false end
    if ok then return all_and end
    return nontrivial == 1
  end
  for _, s in ipairs(segs) do
    local w = words(s.text)
    local pkgs, files = installs(w)
    if pkgs then
      for _, f in ipairs(files) do
        local p = M.relpath(f, root)
        out.entities[#out.entities + 1] = { type = "file", id = "file/" .. p, title = p, edge = "reads", attrs = { path = p } }
      end
      for _, p in ipairs(pkgs) do
        local id = "pkg/" .. p.manager .. "/" .. p.name
        out.entities[#out.entities + 1] = { type = "package", id = id, title = p.name, edge = "installs",
          attrs = { manager = p.manager, name = p.name, version = p.version } }
        if outcome_known(code == 0) then
          local ok = code == 0
          out.claims[#out.claims + 1] = { subject = id, predicate = ok and "installed" or "install_failed",
            title = p.manager .. " install " .. p.name .. (p.version and ("==" .. p.version) or "")
              .. (ok and ": installed" or ": failed") }
        end
      end
    end
    local t = test_of(w)
    if t then
      local id = "test/" .. t:gsub("%s+", "_")
      out.entities[#out.entities + 1] = { type = "test", id = id, title = t, edge = "tests", attrs = { runner = t } }
      if outcome_known(code == 0) then
        out.claims[#out.claims + 1] = { subject = id, predicate = code == 0 and "passed" or "failed",
          title = t .. (code == 0 and ": passed" or ": failed") }
      end
    end
  end
  return out
end

-- extract(call, root) where call = { name, input, result, is_error }
function M.call(call, root)
  local name, input, result = call.name, call.input or {}, call.result or ""
  local out
  if name == "bash" and type(input.command) == "string" then
    out = bash(input, result, root)
  else
    out = { entities = {}, claims = {} }
    if (name == "read" or name == "write" or name == "edit") and type(input.path) == "string" then
      local p = M.relpath(input.path, root)
      local edge = name == "read" and "reads" or (name == "write" and "writes" or "edits")
      local lines = tonumber(result:match("^%S+ lines %d+%-%d+ of (%d+)"))
        or tonumber(result:match("^Wrote .- %(%d+ bytes, (%d+) lines%)"))
        or tonumber(result:match("Post%-edit context %(lines %d+%-%d+ of (%d+)%)"))
      out.entities[1] = { type = "file", id = "file/" .. p, title = p, edge = edge,
        attrs = { path = p, lines = lines, changed = (name ~= "read") and not call.is_error or nil } }
    end
  end
  local failed = call.is_error
  if name == "bash" then
    local code = M.exit_code(result)
    failed = failed or (code ~= nil and code ~= 0)
  end
  if failed then
    local line = M.error_line(result)
    if line then
      out.entities[#out.entities + 1] = { type = "error", id = "error/" .. short(line), title = line,
        edge = "raised", attrs = { line = line } }
    end
  end
  out.failed = failed and true or false
  return out
end

return M
