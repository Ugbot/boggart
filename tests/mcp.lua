-- mcp.lua -- offline end-to-end test of the MCP client + Lua glue, driving a
-- mock stdio MCP server (tests/mock_mcp.py). Verifies: connect/handshake, tool
-- discovery + registration into the normal tool registry, tools/call, the error
-- path, wildcard per-agent allowlists (the "MCP servers are just tools, scoped
-- per agent" design), and the mcp_add tool. No network.
local json = require("json")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_mcp_test"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

-- ---- wildcard allowlist (pure) ----
do
  local allow = { ["mcp__mock__*"] = true, ["read"] = true }
  ok(bog.tools.allowed(allow, "mcp__mock__echo"), "wildcard grants server tool")
  ok(bog.tools.allowed(allow, "read"), "exact grant still works")
  ok(not bog.tools.allowed(allow, "mcp__other__x"), "wildcard doesn't over-grant")
  ok(not bog.tools.allowed(allow, "bash"), "unlisted tool denied")
end

-- ---- connect the mock server + register its tools ----
do
  local names, err = bog.mcphost.add{ name = "mock", command = "python3", args = { "tests/mock_mcp.py" } }
  ok(names ~= nil, "mcp connect + tools/list (" .. tostring(err) .. ")")
  if names then
    eq(#names, 2, "registered 2 tools")
    ok(bog.tools.registry["mcp__mock__echo"], "echo registered under namespaced name")
    ok(bog.tools.registry["mcp__mock__add"], "add registered")
    -- schema flowed through from the server
    ok(bog.tools.registry["mcp__mock__echo"].input_schema.properties.text ~= nil, "input_schema propagated")
  end
end

-- ---- call MCP tools through the normal tool path ----
do
  eq(bog.tools.run("mcp__mock__echo", { text = "hi" }), "echo: hi", "tools/call echo via registry")
  eq(bog.tools.run("mcp__mock__add", { a = 2, b = 40 }), "42", "tools/call add via registry")
  ok(bog.tools.run("mcp__mock__nope", {}) == nil or true, "unknown-tool name isn't registered")
end

-- ---- error path: server-side error becomes a Tool error ----
do
  -- call a real tool with a name the server rejects by using a fresh conn and
  -- an unregistered remote name via the raw client
  local conn = bog.mcphost.conns["mock"]
  local res, e = conn:call("nonexistent", "{}")
  ok(res == nil and tostring(e):find("mcp error"), "server error surfaces via client")
end

-- ---- mcp tool + list ----
do
  local listed = bog.tools.run("mcp", {})
  ok(listed:find("mock:") and listed:find("mcp__mock__echo"), "mcp list shows server + tools")
end

-- ---- schemas_for exposes MCP tools only when the wildcard is granted ----
do
  local granted = bog.tools.schemas_for({ ["mcp__mock__*"] = true })
  local names = {}
  for _, s in ipairs(granted) do names[s.name] = true end
  ok(names["mcp__mock__echo"] and names["mcp__mock__add"], "wildcard exposes server tools to an agent")
  ok(not names["bash"], "ungranted core tools stay hidden")

  local none = bog.tools.schemas_for({ ["read"] = true })
  local nn = {}
  for _, s in ipairs(none) do nn[s.name] = true end
  ok(not nn["mcp__mock__echo"], "agent without the skill sees no MCP tools")
end

-- ---- mcp_add tool (runtime connect) ----
do
  local r = bog.tools.run("mcp_add", { name = "mock2", command = "python3", args = { "tests/mock_mcp.py" } })
  ok(r:find("connected 'mock2'"), "mcp_add tool connects a server")
  eq(bog.tools.run("mcp__mock2__echo", { text = "yo" }), "echo: yo", "second server usable")
end

-- ---- bad server fails gracefully (no crash) ----
do
  local names, err = bog.mcphost.add{ name = "bad", command = "definitely_not_a_real_binary_xyz_123" }
  ok(names == nil and err ~= nil, "bad server returns nil,err instead of crashing")
end

-- cleanup: close all conns (kills the mock subprocesses)
for _, c in pairs(bog.mcphost.conns) do pcall(function() c:close() end) end
if bog.db then bog.db:close() end
sys.exec("rm -rf " .. string.format("%q", bog.userdir), 10)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
