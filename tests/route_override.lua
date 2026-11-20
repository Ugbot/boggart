-- tests/route_override.lua -- a configured endpoint wins over the catalog's.
--
-- A model id the catalog knows used to bring its provider's URL with it, even
-- when ANTHROPIC_BASE_URL (or a stored base_url) named another endpoint: a run
-- meant for a local server with `--model claude-opus-5` went to the vendor's
-- API instead. Now an explicit endpoint holds for every model id, catalogued
-- or not, and the catalog still supplies what it knows about the model.
--
-- The first half drives lua/route.lua with a stored base_url. The second runs
-- the real binary with a catalogued model id and ANTHROPIC_BASE_URL pointing at
-- a stand-in Messages API, with every proxy variable pointing at a trap
-- (tests/fixtures/http/proxy_trap.py) and NO_PROXY covering 127.0.0.1: the
-- stand-in must get the request, and a request for any other host lands in
-- the trap instead of leaving the machine. That half needs BOGGART_TEST_BIN
-- (set by CMake), python3 and a POSIX shell, and says so when it skips.
-- Run: BOGGART_TEST_BIN=$PWD/boggart boggart --eval tests/route_override.lua
local json = require("json")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local function oneline(s) return (tostring(s or ""):gsub("\n", " | "):sub(1, 300)) end

bog.userdir = os.tmpname() .. "_boggart_route_override"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()
local catalog = require("catalog")
catalog.seed_if_empty()
local route = require("route")
local presets = require("presets")

-- A current Claude id from the baked catalog, so the test follows the seed.
local CLAUDE
do
  local cands = {}
  for _, m in ipairs(catalog.models({ provider = "anthropic" })) do cands[#cands + 1] = m.id end
  table.sort(cands)
  for _, id in ipairs(cands) do if id:match("^claude%-opus") then CLAUDE = id end end
  CLAUDE = CLAUDE or cands[1]
end
ck(CLAUDE ~= nil, "the seed catalogues a Claude model")
local row = catalog.model(CLAUDE) or {}

-- ---- in process: a stored base_url ------------------------------------------------
do
  local env_base = os.getenv("ANTHROPIC_BASE_URL")
  local LOCAL = "http://127.0.0.1:9"
  auth.set("base_url", LOCAL)
  local want = (env_base and env_base ~= "") and env_base or LOCAL
  local r = route.resolve(CLAUDE)
  eq(r.url, want, "a catalogued id stays on the configured endpoint")
  eq(r.model, CLAUDE, "and keeps its model id")
  eq(r.wire, route.current().wire, "on the configured wire")
  eq(r.provider, nil, "with no catalog provider attached")
  eq(r.key_slot, nil, "and no catalog key slot (C matches the key to the url)")
  eq(r.context, row.context, "the catalog's context window still applies")
  eq(r.max_output, row.max_output, "the catalog's longest reply still applies")
  eq(r.effort, row.effort, "the catalog's effort capability still applies")

  -- provider/model, with a catalog provider: the prefix named an endpoint,
  -- and the configured endpoint replaces it
  local p = route.resolve("anthropic/" .. CLAUDE)
  eq(p.url, want, "provider/model stays on the configured endpoint")
  eq(p.model, CLAUDE, "and drops the provider prefix")

  -- a preset is a destination written down on purpose: it keeps its own url
  presets.save{ elsewhere = { url = "http://127.0.0.1:7", wire = "openai", model = "m" } }
  eq(route.resolve("elsewhere").url, "http://127.0.0.1:7", "a preset keeps its url")

  -- with nothing configured, the catalog still says where a model lives
  auth.clear("base_url")
  if not (env_base and env_base ~= "") then
    local c = route.resolve(CLAUDE)
    local prow = catalog.provider(row.provider) or {}
    eq(c.url, prow.url, "with no endpoint configured, the catalog's url is used")
    eq(c.provider, row.provider, "and its provider")
  end
end

-- ---- end to end: the request reaches the stand-in and nothing else ----------------
local bin = os.getenv("BOGGART_TEST_BIN")
local posix = package.config:sub(1, 1) == "/"
local function has_python()
  local p = io.popen("command -v python3 2>/dev/null"); if not p then return false end
  local s = p:read("l"); p:close(); return s ~= nil and s ~= ""
end
if bin and bin ~= "" and posix and has_python() then
  local root = os.tmpname()
  os.remove(root)
  sys.mkdir_p(root .. "/work")
  local cwd = (io.popen("pwd"):read("l"))
  local function read_lines(path)
    local f = io.open(path, "r"); if not f then return {} end
    local out = {}
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
  end

  local log, trap_log = root .. "/requests.jsonl", root .. "/trap.log"
  local srv = io.popen(string.format("python3 %q %q 60",
    cwd .. "/tests/fixtures/http/messages_server.py", log), "r")
  local port = tonumber(srv:read("l"))
  local trap = io.popen(string.format("python3 %q %q 60",
    cwd .. "/tests/fixtures/http/proxy_trap.py", trap_log), "r")
  local tport = tonumber(trap:read("l"))
  ck(port ~= nil and tport ~= nil, "stand-in server and proxy trap started")

  local proxy = "http://127.0.0.1:" .. tostring(tport)
  local envs = string.format("env BOGGART_HOME=%q ANTHROPIC_API_KEY=test-key "
    .. "ANTHROPIC_BASE_URL=http://127.0.0.1:%d "
    .. "HTTPS_PROXY=%s https_proxy=%s HTTP_PROXY=%s http_proxy=%s ALL_PROXY=%s all_proxy=%s "
    .. "NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost",
    root .. "/home", port or 0, proxy, proxy, proxy, proxy, proxy, proxy)
  local p = io.popen(string.format("cd %q && %s %q -p %q --model %s </dev/null 2>&1; echo \"EXIT=$?\"",
    root .. "/work", envs, bin, "say done", CLAUDE), "r")
  local out = p:read("a"); p:close()
  local code = tonumber(out:match("EXIT=(%d+)%s*$"))

  local reqs = {}
  for _, line in ipairs(read_lines(log)) do
    local ok, t = pcall(json.decode, line)
    if ok and type(t) == "table" and t.messages then reqs[#reqs + 1] = t end
  end
  local trapped = read_lines(trap_log)
  eq(code, 0, "the run finished [" .. oneline(out) .. "]")
  eq(#reqs, 1, "the stand-in at ANTHROPIC_BASE_URL received the request")
  eq(reqs[1] and reqs[1].model, CLAUDE, "for the catalogued model id")
  eq(#trapped, 0, "no other host was contacted [" .. oneline(table.concat(trapped, "; ")) .. "]")

  pcall(http.request, { url = "http://127.0.0.1:" .. tostring(port) .. "/quit", method = "GET", timeout = 5 })
  pcall(http.request, { url = proxy .. "/quit", method = "GET", timeout = 5 })
  srv:close(); trap:close()
else
  io.write("route_override: end-to-end half skipped (needs BOGGART_TEST_BIN, python3, a POSIX shell)\n")
end

if fails == 0 then
  io.write("ok  route_override: a configured endpoint wins over the catalog's for every model id\n")
else
  io.write(string.format("FAIL route_override: %d check(s) failed\n", fails))
  os.exit(1)
end
