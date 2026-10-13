local scenarios = require "termbench.scenarios"
local json = require "json"
local hash = require "hash_c"
local M = {}
local function positive(value, default, name, maximum)
  value = value == nil and default or value
  assert(type(value) == "number" and value > 0 and value % 1 == 0
    and value <= maximum, name .. " must be an integer in 1.." .. maximum)
  return value
end

local function chunks(data, size)
  local out = {}
  for i = 1, #data, size do out[#out + 1] = data:sub(i, i + size - 1) end
  return out
end
local function with_terminal(backend, opts, fn)
  local terminal = backend.new(opts)
  local ok, result = xpcall(function() return fn(terminal) end, debug.traceback)
  terminal:close()
  if not ok then error(result, 0) end
  return result
end
local function feed(terminal, parts)
  for _, part in ipairs(parts) do terminal:feed(part) end
end

function M.check_stream(backend, case, opts, chunk)
  chunk = positive(chunk, 7, "chunk", 64 * 1024 * 1024)
  local whole = with_terminal(backend, opts, function(t)
    t:feed(case.data)
    return json.encode(t:snapshot())
  end)
  local fragmented = with_terminal(backend, opts, function(t)
    feed(t, chunks(case.data, chunk))
    return json.encode(t:snapshot())
  end)
  assert(whole == fragmented, case.name .. ": stream fragmentation changes terminal state")
  return true
end

function M.run(backend, opts)
  opts = opts or {}
  assert(collectgarbage("isrunning"), "termbench requires normal garbage collection")
  local bytes = positive(opts.bytes, 1024 * 1024, "bytes", 64 * 1024 * 1024)
  local samples = positive(opts.samples, 3, "samples", 100)
  local chunk = positive(opts.chunk, 4096, "chunk", 64 * 1024 * 1024)
  local dims = { cols = positive(opts.cols, 80, "cols", 1000),
    rows = positive(opts.rows, 24, "rows", 1000) }
  local clock = opts.clock or require("uv").hrtime
  local cases, selected, known = scenarios.generate(bytes), {}, {}
  for _, case in ipairs(cases) do
    known[case.name] = true
    if not opts.scenario or opts.scenario == case.name then selected[#selected + 1] = case end
  end
  assert(#selected > 0, "unknown scenario: " .. tostring(opts.scenario))
  for name, budget in pairs(opts.budgets or {}) do
    assert(known[name], "unknown budget scenario: " .. tostring(name))
    assert(not opts.scenario or name == opts.scenario,
      "budget scenario excluded by --scenario: " .. name)
    assert(type(budget) == "table" and type(budget.min_mbps) == "number"
      and budget.min_mbps > 0 and budget.min_mbps < math.huge,
      "budget must contain a positive finite min_mbps: " .. name)
    for key in pairs(budget) do assert(key == "min_mbps", "unknown budget field: " .. key) end
  end
  local report = { schema = 1, backend = backend.name, backend_source = backend.source, target_bytes = bytes,
    chunk_bytes = chunk, cols = dims.cols, rows = dims.rows, samples = samples,
    gc = "enabled", results = {} }
  local problems = {}
  for _, case in ipairs(selected) do
    local missing = {}
    for _, feature in ipairs(case.requires) do
      if not (backend.features or {})[feature] then missing[#missing + 1] = feature end
    end
    assert(not opts.require_features or #missing == 0,
      case.name .. ": backend lacks " .. table.concat(missing, ", "))
    -- Validation is deliberately separate from samples. A fast parser that
    -- drops an escape/UTF-8 fragment must fail before it produces a speed claim.
    M.check_stream(backend, case, dims, 7)
    if chunk ~= 7 then M.check_stream(backend, case, dims, chunk) end
    local parts = chunks(case.data, chunk)
    with_terminal(backend, dims, function(t) feed(t, parts) end) -- warm caches
    local timings = {}
    for i = 1, samples do
      collectgarbage("collect")
      timings[i] = with_terminal(backend, dims, function(t)
        local start = clock()
        feed(t, parts)
        local elapsed = clock() - start
        assert(elapsed > 0, "clock did not advance")
        return elapsed
      end)
    end
    local sorted = { table.unpack(timings) }
    table.sort(sorted)
    local mid = math.floor((samples + 1) / 2)
    local median = samples % 2 == 1 and sorted[mid] or (sorted[mid] + sorted[mid + 1]) / 2
    local result = { scenario = case.name, bytes = #case.data, corpus_sha256 = hash.sha256(case.data), median_ns = median,
      mbps = #case.data * 1000 / median, samples_ns = timings,
      stream_equivalent = true, supported = #missing == 0,
      missing_features = #missing > 0 and missing or json.array }
    local budget = (opts.budgets or {})[case.name]
    if budget then
      result.min_mbps = budget.min_mbps
      result.budget_passed = result.mbps >= budget.min_mbps
      if not result.budget_passed then
        problems[#problems + 1] = string.format("%s: %.3f MB/s below %.3f MB/s budget",
          case.name, result.mbps, budget.min_mbps)
      end
    end
    report.results[#report.results + 1] = result
  end
  assert(#problems == 0, table.concat(problems, "\n"))
  return report
end
return M
