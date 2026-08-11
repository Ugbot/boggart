-- mcphost.lua -- thin Lua glue over the C MCP client (`mcp` global). Connects
-- servers and registers each server tool as an ordinary boggart tool named
-- mcp__<server>__<tool>, so MCP is "just more tools" -- gated per agent by the
-- normal skill allowlists (a skill can grant a whole server via mcp__<name>__*
-- or individual tools). The client lives in C; this is only registration.
local json = require("json")
local M = { conns = {}, tools = {}, info = {} }

-- Flatten an MCP tools/call result (a {content=[...], isError?} object, as JSON
-- text) into a plain string for the tool_result.
local function format_result(result_json)
  local ok, r = pcall(json.decode, result_json)
  if not ok or type(r) ~= "table" then return result_json end
  if type(r.content) == "table" then
    local parts = {}
    for _, blk in ipairs(r.content) do
      if type(blk) == "table" and blk.type == "text" then parts[#parts + 1] = blk.text or ""
      else parts[#parts + 1] = json.encode(blk) end
    end
    local text = table.concat(parts, "\n")
    if r.isError then return "Tool error: " .. text end
    return text ~= "" and text or "(ok)"
  end
  return result_json
end

-- Every page of tools/list, not just the first.
--
-- tools/list is cursor-paginated. The client used to read result.tools and
-- throw the rest away, so a server offering more tools than one page had the
-- remainder silently dropped -- indistinguishable, from the outside, from a
-- server that simply has fewer tools.
--
-- The page cap and the repeat-cursor check are not paranoia about hostile
-- servers so much as about buggy ones: a server that returns the same cursor
-- forever would otherwise hang the connect, and a connect that never returns
-- is a much worse failure than a truncated list.
local MAX_PAGES = 100

local function list_all_tools(conn)
  local out, cursor, seen = {}, nil, {}
  for page = 1, MAX_PAGES do
    local raw, err = conn:list_tools(cursor)
    if not raw then return nil, "tools/list failed: " .. tostring(err) end
    local ok, r = pcall(json.decode, raw)
    if not ok or type(r) ~= "table" then
      return nil, "tools/list returned something that is not an object"
    end
    for _, t in ipairs(r.tools or {}) do out[#out + 1] = t end
    cursor = r.nextCursor
    if type(cursor) ~= "string" or cursor == "" then return out end
    if seen[cursor] then
      return nil, "tools/list repeated the cursor " .. cursor .. " -- refusing to loop"
    end
    seen[cursor] = true
    if page == MAX_PAGES then
      return nil, string.format("tools/list did not finish in %d pages", MAX_PAGES)
    end
  end
  return out
end

-- Connect a server and register its tools. spec:
--   stdio: { name, command, args?, env? }
--   http:  { name, transport="http", url, headers? }
function M.add(spec)
  if type(spec) ~= "table" or type(spec.name) ~= "string" or spec.name == "" then
    return nil, "mcp server spec needs a 'name'"
  end
  if spec.name:find("[^%w_%-]") then
    return nil, "mcp server name must be [A-Za-z0-9_-]"
  end
  local conn, err = mcp.connect(spec)
  if not conn then return nil, err end
  M.conns[spec.name] = conn
  -- Which protocol generation the client negotiated with this server. The C
  -- side decided it during connect (server/discover, then the initialize
  -- handshake if that got nowhere); recording it here is what lets `doctor`
  -- and the studio say "modern" or "legacy" per server instead of leaving the
  -- difference invisible until something behaves oddly.
  local okinfo, info = pcall(json.decode, conn:info())
  M.info[spec.name] = okinfo and type(info) == "table" and info or {}

  local tools, terr = list_all_tools(conn)
  if not tools then return nil, terr end

  local names = {}
  for _, t in ipairs(tools) do
    if type(t) == "table" and type(t.name) == "string" then
      local server = spec.name
      local remote = t.name
      local tname = "mcp__" .. server .. "__" .. remote
      bog.tools.register(tname, {
        description = "[" .. server .. "] " .. (t.description or ""),
        input_schema = t.inputSchema or { type = "object", properties = {} },
        mcp = { server = server, tool = remote }, -- provenance
        run = function(a)
          local c = M.conns[server]
          if not c then return "Tool error: mcp server '" .. server .. "' is not connected" end
          local res, e = c:call(remote, json.encode(a or {}))
          if not res then return "Tool error: " .. tostring(e) end
          return format_result(res)
        end,
      })
      names[#names + 1] = tname
    end
  end
  M.tools[spec.name] = names
  return names
end

-- Connect all servers declared in the ~/.boggart/lua/mcp_servers.lua overlay
-- (a Lua module returning an array of specs). Missing file is fine.
function M.load()
  local ok, servers = pcall(require, "mcp_servers")
  if not ok or type(servers) ~= "table" then return end
  for _, spec in ipairs(servers) do
    local names, err = M.add(spec)
    if names then bog.log(string.format("mcp: connected '%s' (%d tools, %s)",
      spec.name, #names, M.generation(spec.name)))
    else bog.log(string.format("mcp: '%s' failed: %s", tostring(spec.name), tostring(err))) end
  end
end

-- One line per connected server. `era` is "modern" (the stateless 2026-07-28
-- protocol) or "legacy" (the initialize handshake); `protocol` is the exact
-- version in force. Both are additive -- existing callers read .server/.tools.
function M.list()
  local out = {}
  for name, names in pairs(M.tools) do
    local info = M.info[name] or {}
    out[#out + 1] = { server = name, tools = names,
                      era = info.era, protocol = info.protocol }
  end
  table.sort(out, function(a, b) return a.server < b.server end)
  return out
end

-- "modern 2026-07-28" / "legacy 2025-11-25" / "" for a server we never reached.
function M.generation(name)
  local info = M.info[name]
  if not info or not info.era then return "" end
  return info.era .. " " .. tostring(info.protocol or "?")
end

return M
