-- Development tool, intentionally outside the embedded product scripts.
local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local tools = assert(source:match("^(.*)/[^/]+$"))
package.path = tools .. "/?.lua;" .. tools .. "/?/init.lua;" .. package.path
local json = require "json"
local runner = require "termbench.runner"
local function read_json(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("a")
  file:close()
  local value = json.decode(data)
  assert(type(value) == "table", "expected a JSON object: " .. path)
  return value
end
local function main(args)
  local opts, backend_name, output, as_json = {}, "termbench.backends.lua", nil, false
  local number_options = { ["--bytes"] = "bytes", ["--samples"] = "samples",
    ["--chunk"] = "chunk", ["--cols"] = "cols", ["--rows"] = "rows" }
  local i = 1
  while i <= #args do
    local arg = args[i]
    if arg == "--help" then
      io.write("Usage: boggart --eval tools/termbench.lua -- [options]\n",
        "  --bytes N       bytes per scenario (default 1048576, rounded to complete units)\n",
        "  --samples N     timed samples after warmup (default 3)\n",
        "  --chunk N       feed chunk bytes (default 4096)\n",
        "  --cols N --rows N  terminal dimensions (default 80 x 24)\n",
        "  --scenario NAME plain|dense-sgr|unicode|scroll|alt-screen\n",
        "  --backend MODULE  Lua backend adapter (default termbench.backends.lua)\n",
        "  --json          JSON on stdout\n",
        "  --output PATH   also save the JSON report\n",
        "  --budgets PATH  JSON object: {scenario: {min_mbps: number}}\n",
        "  --require-features  fail for any unsupported scenario feature\n")
      return
    elseif arg == "--json" then as_json = true
    elseif arg == "--require-features" then opts.require_features = true
    else
      local value = args[i + 1]
      assert(value, "missing value for " .. arg)
      if number_options[arg] then
        opts[number_options[arg]] = assert(tonumber(value), "invalid number for " .. arg)
      elseif arg == "--scenario" then opts.scenario = value
      elseif arg == "--backend" then backend_name = value
      elseif arg == "--output" then output = value
      elseif arg == "--budgets" then opts.budgets = read_json(value)
      else error("unknown option: " .. arg) end
      i = i + 1
    end
    i = i + 1
  end
  local report = runner.run(require(backend_name), opts)
  local uv = require "uv"
  report.environment = { uname = uv.os_uname(), libuv = uv.version_string(),
    boggart = bog.version, lua = _VERSION, measured_at_utc = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  local encoded = json.encode(report)
  if output then
    local file = assert(io.open(output, "wb"))
    assert(file:write(encoded, "\n"))
    assert(file:close())
  end
  if as_json then io.write(encoded, "\n")
  else
    io.write(string.format("termbench: %s, %dx%d, %d samples, %d-byte chunks, GC enabled\n",
      report.backend, report.cols, report.rows, report.samples, report.chunk_bytes))
    for _, result in ipairs(report.results) do
      io.write(string.format("  %-12s %8.3f MB/s  %8.2f ms  %d bytes",
        result.scenario, result.mbps, result.median_ns / 1e6, result.bytes))
      if not result.supported then
        io.write("  lacks: ", table.concat(result.missing_features, ", "))
      end
      io.write("\n")
    end
    io.write("ok  whole and fragmented streams agree; throughput is not conformance\n")
  end
end
local ok, err = xpcall(function() main(boggart.args or {}) end, debug.traceback)
if not ok then io.stderr:write("termbench: ", tostring(err), "\n"); return 1 end
return 0
