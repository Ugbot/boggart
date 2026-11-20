-- tests/help.lua -- --help names every environment setting an unattended run reads.
--
-- A benchmark harness or a CI job configures boggart through the environment,
-- and --help is where it looks. Settings that existed but were not listed
-- (BOGGART_TOOLS, BOGGART_HEADLESS_POLICY, ...) could only be found by reading
-- the source. The run settings in lua/runflags.lua are checked from that
-- module's own table, so a new one cannot be added without documenting it.
-- Needs BOGGART_TEST_BIN (set by CMake), and says so when it skips.
-- Run: BOGGART_TEST_BIN=$PWD/boggart boggart --eval tests/help.lua
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

local bin = os.getenv("BOGGART_TEST_BIN")
if not (bin and bin ~= "") then
  io.write("help: skipped (needs BOGGART_TEST_BIN)\n")
  return 0
end

local p = io.popen(string.format("%q --help 2>&1; echo \"EXIT=$?\"", bin), "r")
local out = p:read("a"); p:close()
ck(out:match("EXIT=0%s*$") ~= nil, "--help exits 0")
local env_part = out:match("\nenvironment:(.*)$") or ""
ck(env_part ~= "", "--help has an environment section")

local want = {
  -- where requests go, and with what
  "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_WIRE", "<PROVIDER>_API_KEY",
  -- the run
  "BOGGART_TOOLS", "BOGGART_HEADLESS_POLICY", "BOGGART_SKILL_TRUST",
  -- the fleet
  "BOGGART_MAX_AGENTS", "BOGGART_AUTO_DISPATCH",
  -- output and data
  "NO_COLOR", "BOGGART_TRACE", "BOGGART_HOME",
  -- graph memory (lua/ctxgraph.lua) and model request timeouts (lua/api.lua)
  "BOGGART_MEMORY", "BOGGART_GRAPH_AUTOEXPAND",
  "BOGGART_IDLE_TIMEOUT", "BOGGART_REQUEST_TIMEOUT", "BOGGART_CONNECT_TIMEOUT",
}
for _, s in ipairs(require("runflags").SETTINGS) do want[#want + 1] = s.env end
for _, name in ipairs(want) do
  ck(env_part:find(name, 1, true) ~= nil, "--help environment lists " .. name)
end
-- Every runflags setting has its flag in the options part too, and so does
-- the memory tier, which runflags reads beside SETTINGS.
local opts_part = out:match("^(.-)\nenvironment:") or ""
local flags = { "--memory" }
for _, s in ipairs(require("runflags").SETTINGS) do flags[#flags + 1] = s.flag end
for _, f in ipairs(flags) do
  ck(opts_part:find(f, 1, true) ~= nil, "--help options list " .. f)
end
-- The timeouts are read by lua/api.lua: if a name there changes, --help must too.
local api_src = io.open("lua/api.lua"):read("a")
for name in api_src:gmatch('env_seconds%("(BOGGART_[%u_]+)"') do
  ck(env_part:find(name, 1, true) ~= nil, "--help environment lists " .. name .. " (read in lua/api.lua)")
end
-- The policy's values, since an unset one refuses every gated tool.
ck(env_part:find("allow", 1, true) and env_part:find("queue", 1, true),
   "--help says what BOGGART_HEADLESS_POLICY accepts")

if fails == 0 then
  io.write("ok  help: --help lists every environment setting an unattended run reads\n")
else
  io.write(string.format("FAIL help: %d check(s) failed\n", fails))
  os.exit(1)
end
