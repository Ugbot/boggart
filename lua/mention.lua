-- mention.lua -- expand @tokens in a prompt so the TUI and the studio attach
-- the same context. One expander, both fronts.
--
-- Beyond @path (a file, attached verbatim), tokens carry kinds: @code:query
-- and @docs:query (ranked search, station over ZMQ when up, native tiers
-- when down), @git:ref (git show), @folder:dir (a listing), @url: (fetched
-- via station), and the ambient @problems / @terminal resolved through
-- M.sources. A mention only counts when the @ opens a word (start,
-- whitespace, or ([{,;: before it; user@host is never a mention), and a
-- token needs two characters.
--
-- Expansion rides the outgoing payload; the bubble shows what was typed.
local M = {}
M.MAX = 64 * 1024

-- Front ends register ambient sources: M.sources.problems = function()
-- return "text" end. Unregistered ambient mentions report as unresolved.
M.sources = {}

local function read_path(path)
  path = tostring(path or ""):gsub("^~", sys.home and sys.home() or "")
  if path == "" then return nil, path end
  local body = bog and bog.util and bog.util.read_file and bog.util.read_file(path)
  return body, path
end

-- If `token` is not itself a file, ask the completer for a unique file hit so
-- `@complete` attaches lua/complete.lua the way Tab would have filled it in.
function M.resolve(token)
  local body, path = read_path(token)
  if body then return path, body end
  if not (bog and type(bog.complete) == "function") then return nil end
  local ok, items = pcall(bog.complete, "@" .. token)
  if not ok or type(items) ~= "table" then return nil end
  local files = {}
  for _, it in ipairs(items) do
    local t = type(it) == "table" and (it.text or "") or tostring(it or "")
    if t:sub(1, 1) == "@" and t:sub(-1) ~= "/" then
      files[#files + 1] = t:sub(2)
    end
  end
  if #files ~= 1 then return nil end
  body, path = read_path(files[1])
  if body then return path, body end
  return nil
end

-- Returns kind, rest: the payload after a prefix, or the token itself.
local KIND_PREFIX = { code = true, docs = true, folder = true, dir = true,
                      url = true, git = true }

function M.classify(token)
  if token == "problems" or token == "terminal" then return token, nil end
  if token:match("^https?://") then return "url", token end
  local p, rest = token:match("^(%a+):(.+)$")
  if p and KIND_PREFIX[p] then
    return (p == "dir") and "folder" or p, rest
  end
  if token:sub(-1) == "/" then return "folder", token end
  if token:find("/", 1, true) or token:match("%.%a") then return "file", token end
  return "symbol", token
end

-- sys.exec has returned a bare string and a { out = ... } table; accept both.
local function exec_out(cmd, timeout)
  local ok, r = pcall(sys.exec, cmd, timeout or 10)
  if not ok then return nil end
  if type(r) == "string" then return r end
  if type(r) == "table" and type(r.out) == "string" then return r.out end
  return nil
end

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function search(query)
  if not (bog and bog.tools and bog.tools.run) then return nil end
  local ok, res = pcall(bog.tools.run, "code_search", { query = query, limit = 8 })
  if not ok or type(res) ~= "string" or res:find("^Tool error:") then return nil end
  return res
end

-- Resolve a kinded mention to text, or nil. Bounded and best-effort: an
-- unresolvable mention becomes a note, never an error.
function M.resolve_kind(kind, rest)
  if kind == "problems" or kind == "terminal" then
    local src = M.sources[kind]
    if type(src) == "function" then
      local ok, out = pcall(src)
      if ok and type(out) == "string" and out ~= "" then return out end
    end
    return nil
  end
  if kind == "code" then return search(rest) end
  if kind == "docs" then
    -- Station's semantic search when up; ranked code search is the floor.
    local oks, stn = pcall(require, "stationlink")
    if oks and stn and stn.up and stn.up() then
      local out = stn.call("semantic_search", { query = rest, limit = "8" })
      if out and out ~= "" then return out end
    end
    return search(rest)
  end
  if kind == "git" then
    if rest:find("[^%w%._%-/~^]") then return nil end -- refs only
    return exec_out("git show --stat --format=medium " .. shq(rest) .. " 2>/dev/null", 10)
  end
  if kind == "folder" then
    local dir = tostring(rest):gsub("^~", sys.home and sys.home() or ""):gsub("/+$", "")
    local names = sys.listdir and sys.listdir(dir ~= "" and dir or "/")
    if type(names) ~= "table" or #names == 0 then return nil end
    table.sort(names)
    return table.concat(names, "\n")
  end
  if kind == "url" then
    local oks, stn = pcall(require, "stationlink")
    if oks and stn and stn.up and stn.up() then
      local out = stn.call("fetch_url", { url = rest })
      if out and out ~= "" then return out end
    end
    return nil
  end
  return nil
end

-- Walk @tokens in `text`. Returns the prompt with attachments appended and a
-- note list { { path=, bytes=, ok=bool } }. An email address is no mention
-- and leaves no note.
function M.expand(text)
  text = tostring(text or "")
  local seen, attach, notes = {}, {}, {}
  local pos = 1
  while true do
    local s, e, token = text:find("@([%w%._%-/~:+]+)", pos)
    if not s then break end
    pos = e + 1
    local opens = s == 1 or text:sub(s - 1, s - 1):match("[%s%(%[{,;:]") ~= nil
    token = token:gsub(":+$", "") -- a clause-final "@foo:" is @foo
    if opens and #token >= 2 and not seen[token] then
      seen[token] = true
      local kind, rest = M.classify(token)
      local label, body
      if kind == "file" or kind == "symbol" then
        label, body = M.resolve(token)
      else
        body = M.resolve_kind(kind, rest)
        label = token
      end
      if body then
        local note = ""
        if #body > M.MAX then
          body = body:sub(1, M.MAX)
          note = string.format("\n... (truncated at %d KB)", M.MAX // 1024)
        end
        attach[#attach + 1] = string.format("--- %s ---\n%s%s", label, body, note)
        notes[#notes + 1] = { path = label, bytes = #body, ok = true, kind = kind }
      else
        notes[#notes + 1] = { path = token, bytes = 0, ok = false, kind = kind }
      end
    end
  end
  if #attach == 0 then return text, notes end
  return text .. "\n\n" .. table.concat(attach, "\n\n"), notes
end

return M
