-- mention.lua -- expand @path tokens in a prompt so the TUI and the studio
-- attach the same files. Studio used to do this only in AgentView; the cTUI
-- sent the raw @token and the model had to read(). One expander, both fronts.
local M = {}
M.MAX = 64 * 1024

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

-- Walk `@tokens` in `text`. Returns the prompt with attachments appended, and
-- a note list { { path=, bytes=, ok=bool } } so a front end can tell the user
-- what landed (or what did not).
function M.expand(text)
  text = tostring(text or "")
  local seen, attach, notes = {}, {}, {}
  for token in text:gmatch("@([%w%._%-/~]+)") do
    if not seen[token] then
      seen[token] = true
      local path, body = M.resolve(token)
      if body then
        local note = ""
        if #body > M.MAX then
          body = body:sub(1, M.MAX)
          note = string.format("\n... (truncated at %d KB)", M.MAX // 1024)
        end
        attach[#attach + 1] = string.format("--- %s ---\n%s%s", path, body, note)
        notes[#notes + 1] = { path = path, bytes = #body, ok = true }
      else
        notes[#notes + 1] = { path = token, bytes = 0, ok = false }
      end
    end
  end
  if #attach == 0 then return text, notes end
  return text .. "\n\n" .. table.concat(attach, "\n\n"), notes
end

return M
