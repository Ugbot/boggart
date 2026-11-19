-- tools.lua -- the tool list as a stable prompt prefix (lua/tools.lua).
--
-- Tool schemas are rendered near the start of every request, so a provider
-- that caches by exact prefix loses everything after the first byte that
-- changes. A tool added mid-run (define_tool, reload, a skill, an MCP server)
-- must therefore land at the END of the list, never in the middle, and the
-- same schema must always encode to the same bytes.
local json = require("json")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

local tools = bog.tools

local function encode_all(list)
  local out = {}
  for i, s in ipairs(list) do out[i] = json.encode(s) end
  return table.concat(out, "\n")
end
local function is_prefix(a, b)
  if #a > #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end
local function index(list, name)
  for i, v in ipairs(list) do if (v.name or v) == name then return i end end
end

-- ---- base tools: a deterministic, sorted boot order -------------------------
local names0 = tools.names()
local sorted = {}
for i, n in ipairs(names0) do sorted[i] = n end
table.sort(sorted)
ok(table.concat(names0, ",") == table.concat(sorted, ","),
   "tools present at the first listing are in sorted order")
ok(table.concat(tools.names(), ",") == table.concat(names0, ","),
   "listing again gives the same order")

-- ---- encoding is byte-identical across calls ------------------------------
local enc1 = encode_all(tools.schemas())
local enc2 = encode_all(tools.schemas())
ok(enc1 == enc2, "schemas encode byte-identically across calls")
-- the same schema built in a different key-insertion order encodes the same
local a = { type = "object", properties = {}, required = { "x" } }
a.properties.x = { type = "string", description = "x" }
a.properties.b = { type = "integer" }
local b = { required = { "x" } }
b.properties = { b = { type = "integer" } }
b.properties.x = { description = "x", type = "string" }
b.type = "object"
ok(json.encode(a) == json.encode(b), "key order does not depend on insertion order")
ok(json.lua_encode(a) == json.encode(a) and json.lua_encode(b) == json.encode(b),
   "the native and Lua encoders agree")

-- ---- a tool defined mid-run appends; the old prefix is untouched -----------
-- "aaa_" sorts before every built-in, so a sorted list would put it first and
-- change every byte after it.
local before_schemas = tools.schemas()
local before_enc = {}
for i, s in ipairs(before_schemas) do before_enc[i] = json.encode(s) end
local r = tools.registry.define_tool.run({ name = "aaa_probe", description = "probe",
  lua = "return 'ok'", scope = "session" })
ok(type(r) == "string" and r:find("Defined tool 'aaa_probe'"), "define_tool (session) works: " .. tostring(r))
local names1 = tools.names()
ok(is_prefix(names0, names1), "existing tools keep their positions after define_tool")
ok(names1[#names1] == "aaa_probe", "the new tool appends at the end")
local after_enc = {}
for i, s in ipairs(tools.schemas()) do after_enc[i] = json.encode(s) end
ok(is_prefix(before_enc, after_enc), "schemas before and after share the full old prefix")
ok(#after_enc == #before_enc + 1, "exactly one schema was added")

-- several tools arriving together append in a deterministic (sorted) batch
tools.register("aab_two", { description = "two", run = function() return "" end })
tools.register("aab_one", { description = "one", run = function() return "" end })
local names2 = tools.names()
ok(is_prefix(names1, names2), "a batch of new tools keeps the old prefix")
ok(names2[#names2 - 1] == "aab_one" and names2[#names2] == "aab_two",
   "a batch appends in sorted order")

-- redefining a tool keeps its slot
tools.registry.define_tool.run({ name = "aaa_probe", description = "probe v2",
  lua = "return 'ok2'", scope = "session" })
ok(table.concat(tools.names(), ",") == table.concat(names2, ","), "redefining keeps the slot")

-- a tool that goes away and comes back returns to its old slot
local saved = tools.registry.read
tools.registry.read = nil
ok(index(tools.names(), "read") == nil, "a removed tool is not listed")
tools.registry.read = saved
ok(table.concat(tools.names(), ",") == table.concat(names2, ","),
   "a re-registered tool returns to its old position")

-- ---- schemas_for keeps the same relative order ------------------------------
local allow = { aaa_probe = true, write = true, read = true, ["aab_*"] = true }
local sub = {}
for i, s in ipairs(tools.schemas_for(allow)) do sub[i] = s.name end
ok(table.concat(sub, ",") == "read,write,aaa_probe,aab_one,aab_two",
   "schemas_for follows registry order: " .. table.concat(sub, ","))

-- ---- the order survives a harness reload -----------------------------------
local ok_reload, rerr = bog.reload()
ok(ok_reload, "reload succeeds: " .. tostring(rerr))
tools = bog.tools
tools.register("aaa_probe", { description = "probe", input_schema = { type = "object", properties = {} },
  run = function() return "" end })
tools.register("aab_one", { description = "one", run = function() return "" end })
tools.register("aab_two", { description = "two", run = function() return "" end })
local names3 = tools.names()
ok(is_prefix(names0, names3), "base tools keep their positions across reload")
ok(table.concat(names3, ",") == table.concat(names2, ","),
   "tools added before a reload keep their positions after it")
tools.register("aac_after_reload", { description = "late", run = function() return "" end })
local names4 = tools.names()
ok(names4[#names4] == "aac_after_reload" and is_prefix(names3, names4),
   "a tool added after reload appends")

io.write(string.format("tools: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
