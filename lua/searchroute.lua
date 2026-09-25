-- searchroute.lua -- when LLM Station is up, code search goes to LLM Station.
--
-- The model searches code through `bash`: in practice `grep -rn`, `rg` and
-- `find -name` account for nearly every lookup, and a dedicated search tool is
-- almost never chosen over them. So the place to route search is the place
-- search actually happens: the bash tool. When the ZMQ link to LLM Station is
-- live, a bash command that is a plain search is answered by the daemon's own
-- tool instead of by a local subprocess; everything else runs exactly as typed.
--
-- The rule that matters is FIDELITY. A search is rerouted only when the
-- daemon can answer it with the same meaning: grep_search is a regex walk
-- (C++ std::regex, ECMAScript flavour) with one path, an optional filename
-- glob, context lines and a result cap -- no case folding, no inverted match,
-- no file-list mode. A command using anything outside that (-i, -v, -l,
-- several paths, a shell glob, a pipe into anything but head, a redirect) is
-- left to the shell, because silently changing what a search means is worse
-- than not routing it. translate() is pure, so the whole mapping is tested
-- without a daemon (tests/searchroute.lua).
--
--   searchroute.translate(cmd, cwd) -> { tool=, params=, summary= } | nil, why
--   searchroute.run(cmd, cwd)       -> output | nil, why   (nil: run it natively)
local M = {}

-- ---- a small shell-word tokenizer --------------------------------------------
-- Words with '…' / "…" quoting and backslash escapes. Anything that makes the
-- shell do more than split words -- expansion, redirection, sequencing,
-- subshells, globbing -- returns nil: that command is not a plain search.
local SPECIAL = { ["$"] = true, ["`"] = true, [">"] = true, ["<"] = true,
                  [";"] = true, ["("] = true, [")"] = true, ["{"] = true, ["}"] = true }

function M.tokenize(cmd)
  local words, cur, i, n = {}, nil, 1, #cmd
  local function push() if cur then words[#words + 1] = cur; cur = nil end end
  while i <= n do
    local c = cmd:sub(i, i)
    if c:match("%s") then push()
    elseif c == "'" then
      local j = cmd:find("'", i + 1, true)
      if not j then return nil, "unterminated quote" end
      cur = (cur or "") .. cmd:sub(i + 1, j - 1); i = j
    elseif c == '"' then
      local buf, j = {}, i + 1
      while j <= n do
        local d = cmd:sub(j, j)
        if d == '"' then break end
        if d == "$" or d == "`" then return nil, "expansion inside double quotes" end
        if d == "\\" and j < n then
          local e = cmd:sub(j + 1, j + 1)
          if e == '"' or e == "\\" or e == "$" or e == "`" then buf[#buf + 1] = e; j = j + 1
          else buf[#buf + 1] = d end
        else buf[#buf + 1] = d end
        j = j + 1
      end
      if j > n then return nil, "unterminated quote" end
      cur = (cur or "") .. table.concat(buf); i = j
    elseif c == "\\" then
      if i == n then return nil, "trailing backslash" end
      cur = (cur or "") .. cmd:sub(i + 1, i + 1); i = i + 1
    elseif c == "|" then
      push(); words[#words + 1] = { op = (cmd:sub(i + 1, i + 1) == "|") and "||" or "|" }
      if cmd:sub(i + 1, i + 1) == "|" then i = i + 1 end
    elseif c == "&" then
      push()
      if cmd:sub(i + 1, i + 1) ~= "&" then return nil, "background job" end
      words[#words + 1] = { op = "&&" }; i = i + 1
    elseif SPECIAL[c] then return nil, "shell syntax: " .. c
    elseif (c == "*" or c == "?" or c == "[") then
      -- An unquoted glob: the shell expands it into paths we cannot see.
      return nil, "unquoted glob"
    else cur = (cur or "") .. c end
    i = i + 1
  end
  push()
  return words
end

-- ---- pattern dialects -> ECMAScript --------------------------------------------
local META = "[%^%$%.%*%+%?%(%)%[%]%{%}%|\\/]"
function M.escape_regex(s) return (s:gsub(META, "\\%0")) end

-- grep's default is a BASIC regex, where + ? ( ) { } | are literal and their
-- backslashed forms are operators -- the reverse of ECMAScript. Translating
-- that faithfully is a parser; a pattern that uses none of those characters
-- means the same in both, which covers identifiers, words and simple . * ^ $.
local function bre_ok(p) return not p:find("[%+%?%(%)%{%}|\\]") end

-- ---- grep / rg ----------------------------------------------------------------
local function int(s) local v = tonumber(s); return v and math.type(v) == "integer" and v >= 0 and v or nil end

local function parse_grep(args, is_rg)
  local o = { recursive = is_rg, dialect = is_rg and "ere" or "bre" }
  local pats, paths, i = {}, {}, 1
  local function need(v, why) if v == nil then error(why, 0) end return v end
  while i <= #args do
    local a = args[i]
    if a == "--" then
      for j = i + 1, #args do if #pats == 0 and not o.e then pats[1] = args[j] else paths[#paths + 1] = args[j] end end
      break
    elseif a:sub(1, 2) == "--" then
      local k, v = a:match("^%-%-([%w%-]+)=(.*)$")
      k = k or a:sub(3)
      if k == "include" and v and not is_rg then o.glob = need(o.glob == nil and v or nil, "several --include")
      elseif k == "glob" and is_rg then o.glob = need(o.glob == nil and (v or args[i + 1]) or nil, "several globs"); if not v then i = i + 1 end
      elseif k == "fixed-strings" then o.dialect = "fixed"
      elseif k == "extended-regexp" and not is_rg then o.dialect = "ere"
      elseif k == "word-regexp" then o.word = true
      elseif k == "recursive" and not is_rg then o.recursive = true
      elseif k == "line-number" or k == "with-filename" or k == "no-heading"
          or k == "binary-files" and v == "without-match" then -- presentation only
      elseif k == "max-count" and is_rg then return nil, "per-file max-count"
      elseif k == "context" then o.context = need(int(v or args[i + 1]), "bad --context"); if not v then i = i + 1 end
      else return nil, "flag --" .. k end
    elseif a:sub(1, 1) == "-" and #a > 1 then
      local j = 2
      while j <= #a do
        local f = a:sub(j, j)
        if f == "r" or f == "R" then o.recursive = true
        elseif f == "n" or f == "H" or f == "I" or f == "s" or (is_rg and f == "N") then -- presentation / binary skip
        elseif f == "E" and not is_rg then o.dialect = "ere"
        elseif f == "F" then o.dialect = "fixed"
        elseif f == "w" then o.word = true
        elseif f == "e" then
          local v = a:sub(j + 1); if v == "" then i = i + 1; v = args[i] end
          if v == nil or o.e then return nil, "several -e patterns" end
          o.e = v; pats[1] = v; break
        elseif f == "C" or f == "m" or (is_rg and f == "g") then
          local v = a:sub(j + 1); if v == "" then i = i + 1; v = args[i] end
          if v == nil then return nil, "-" .. f .. " needs a value" end
          if f == "C" then o.context = int(v); if not o.context then return nil, "bad -C" end
          elseif f == "m" then return nil, "per-file -m"
          else if o.glob or v:sub(1, 1) == "!" then return nil, "rg glob form" end; o.glob = v end
          break
        else return nil, "flag -" .. f end
        j = j + 1
      end
    elseif #pats == 0 and not o.e then pats[1] = a
    else paths[#paths + 1] = a end
    i = i + 1
  end
  if #pats ~= 1 then return nil, "no pattern" end
  if #paths > 1 then return nil, "several paths" end
  if #paths == 0 and not o.recursive then return nil, "grep without -r reads stdin" end
  local p = pats[1]
  if p == "" then return nil, "empty pattern" end
  if o.dialect == "fixed" then p = M.escape_regex(p)
  elseif o.dialect == "bre" and not bre_ok(p) then return nil, "basic-regex operators" end
  if p:find("%[%[:") then return nil, "POSIX character class" end
  if o.word then p = "\\b" .. p .. "\\b" end
  return { pattern = p, path = paths[1] or ".", glob = o.glob, context = o.context }
end

-- ---- find -------------------------------------------------------------------------
local function parse_find(args)
  local path, name, i = nil, nil, 1
  if args[1] and args[1]:sub(1, 1) ~= "-" then path = args[1]; i = 2 end
  while i <= #args do
    local a = args[i]
    if a == "-name" then
      if name then return nil, "several -name" end
      name = args[i + 1]; i = i + 1
      if not name then return nil, "-name needs a value" end
    elseif a == "-type" and args[i + 1] == "f" then i = i + 1
    else return nil, "find " .. a end
    i = i + 1
  end
  if not name then return nil, "find without -name" end
  if name:find("/", 1, true) then return nil, "-name with a slash" end
  return { pattern = "**/" .. name, path = path or "." }
end

-- ---- the command ------------------------------------------------------------------
local function join(dir, p)
  if p:sub(1, 1) == "/" then return p end
  if p == "." then return dir end
  return (dir:gsub("/+$", "")) .. "/" .. p:gsub("^%./", "")
end

-- cmd -> { tool, params, summary } | nil, why. `cwd` resolves relative paths
-- (the daemon's own root is the workspace, not our cwd, so every path sent is
-- absolute).
function M.translate(cmd, cwd)
  if type(cmd) ~= "string" then return nil, "no command" end
  local words, why = M.tokenize(cmd)
  if not words then return nil, why end
  cwd = cwd or (sys and sys.cwd and sys.cwd()) or "."

  -- optional leading `cd DIR &&`
  local i = 1
  if words[1] == "cd" and type(words[2]) == "string" and type(words[3]) == "table"
     and words[3].op == "&&" then
    cwd = join(cwd, words[2]); i = 4
  end
  -- the command proper, up to an optional `| head [-n] N`
  local cmdw, limit = {}, nil
  while i <= #words do
    local w = words[i]
    if type(w) == "table" then
      if w.op ~= "|" then return nil, "sequencing" end
      local h1, h2, h3 = words[i + 1], words[i + 2], words[i + 3]
      if h1 ~= "head" then return nil, "pipe into " .. tostring(h1) end
      if h2 == nil then limit = 10
      elseif h2 == "-n" and int(h3) and words[i + 4] == nil then limit = int(h3)
      elseif type(h2) == "string" and h2:match("^%-%d+$") and h3 == nil then limit = int(h2:sub(2))
      elseif type(h2) == "string" and h2:match("^%-n%d+$") and h3 == nil then limit = int(h2:sub(3))
      else return nil, "head form" end
      break
    end
    cmdw[#cmdw + 1] = w; i = i + 1
  end
  local prog = cmdw[1]
  local args = {}
  for k = 2, #cmdw do args[#args + 1] = cmdw[k] end

  if prog == "grep" or prog == "rg" then
    local ok, g, gwhy = pcall(parse_grep, args, prog == "rg")
    if not ok then return nil, tostring(g) end
    if not g then return nil, gwhy end
    local params = { pattern = g.pattern, path = join(cwd, g.path) }
    if g.glob then params.glob = g.glob end
    if g.context and g.context > 0 then params.context_lines = g.context end
    if limit then params.max_results = limit end
    return { tool = "grep_search", params = params,
             summary = string.format("grep_search %s in %s", g.pattern, params.path) }
  elseif prog == "find" then
    local f, fwhy = parse_find(args)
    if not f then return nil, fwhy end
    return { tool = "glob_search", params = { pattern = f.pattern, path = join(cwd, f.path) },
             summary = string.format("glob_search %s in %s", f.pattern, join(cwd, f.path)),
             limit = limit }
  end
  return nil, "not a search command"
end

-- ---- dispatch -------------------------------------------------------------------------
M.stats = { routed = 0, native = 0, failed = 0 }

-- Is routing on? The link must be live (or startable, via stationlink.active's
-- autostart), and it can be switched off (BOGGART_STATION_SEARCH=0) to compare.
function M.enabled()
  if os.getenv("BOGGART_STATION_SEARCH") == "0" then return false end
  local ok, stn = pcall(require, "stationlink")
  return ok and stn and stn.active and stn.active() or false
end

-- Answer `cmd` through the daemon, or return nil so the caller runs it natively.
-- A daemon failure is never an answer: the shell gets the command instead.
function M.run(cmd, cwd)
  local t = M.translate(cmd, cwd)
  if not t then return nil end
  if not M.enabled() then return nil end
  local stn = require("stationlink")
  local out, err = stn.call(t.tool, t.params)
  if not out then
    M.stats.failed = M.stats.failed + 1
    if bog and bog.log then bog.log("station search failed, running natively: " .. tostring(err)) end
    return nil
  end
  if t.limit then
    local lines, n = {}, 0
    for line in (out .. "\n"):gmatch("(.-)\n") do
      n = n + 1; if n > t.limit then break end
      lines[#lines + 1] = line
    end
    out = table.concat(lines, "\n")
  end
  M.stats.routed = M.stats.routed + 1
  return "[answered by llm-station " .. t.summary .. "]\n" .. out
end

return M
