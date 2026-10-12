-- uilarge.lua -- open a 500 MB log in the studio editor and measure it (BOG-25).
-- BOGGART_STUDIO_SCRIPT=tools/uilarge.lua BOGGART_STUDIO_SHOT=out.bmp boggart-studio <repo>
local core = require "core"
local OUT = os.getenv("BOGGART_STUDIO_SHOT") or "/tmp/boggart-large.bmp"
local problems = {}
core.add_thread(function() local okrun, why = pcall(function()
  local function frame(n) core.redraw = true; for _ = 1, (n or 3) do coroutine.yield(0) end end
  local path = sys.tmpdir() .. "/uilarge-" .. tostring(os.time()) .. ".log"
  local f = io.open(path, "wb")
  local blk = {}
  for i = 1, 8192 do blk[i] = string.format("2026-10-02T12:00:%02d.%06d INFO  worker-%02d request ok latency=%dms path=/api/v1/items\n", i % 60, i, i % 16, i % 900) end
  local chunk = table.concat(blk)
  local written = 0
  while written < 500 * 1048576 do f:write(chunk); written = written + #chunk end
  f:close()
  local mem0 = sys.membytes and sys.membytes() or 0
  local t0 = system.get_time()
  local doc = core.open_doc(path)
  local tdoc = (system.get_time() - t0) * 1000
  local samples = {}
  if os.getenv("UILARGE_PROFILE") then
    debug.sethook(function()
      for lvl = 2, 6 do
        local info = debug.getinfo(lvl, "Sl")
        if info and info.short_src and not info.short_src:find("uilarge") then
          local k = info.short_src .. ":" .. (info.linedefined or 0)
          samples[k] = (samples[k] or 0) + 1
          break
        end
      end
    end, "", 20000)
  end
  local dv = core.root_view:open_doc(doc)
  debug.sethook()
  local top = {}
  for k, v in pairs(samples) do top[#top + 1] = { k = k, v = v } end
  table.sort(top, function(a, b) return a.v > b.v end)
  for i = 1, math.min(8, #top) do io.stderr:write(string.format("uilarge: profile %5d  %s\n", top[i].v, top[i].k)) end
  local topen = (system.get_time() - t0) * 1000
  local tf = system.get_time()
  frame(1)
  local tframe = (system.get_time() - tf) * 1000
  io.stderr:write(string.format("uilarge: stages -- load %.1f ms, view %.1f ms, first frame %.1f ms\n", tdoc, topen - tdoc, tframe))
  frame(3)
  if not doc.large then problems[#problems + 1] = "not opened as a large-file view" end
  -- scroll through it, timing frames
  local worst, n = 0, 0
  for _, target in ipairs{ 1000, 100000, 1000000, 3000000, 4500000, 10 } do
    local line = math.min(target, #doc.lines)
    doc:set_selection(line, 1)
    dv:scroll_to_line(line, true, true)
    local t1 = system.get_time()
    frame(2)
    local dt = (system.get_time() - t1) * 1000
    if dt > worst then worst = dt end
    n = n + 1
  end
  system.save_screenshot((OUT:gsub("%.bmp$", "")) .. "-deep.bmp")
  local mem1 = sys.membytes and sys.membytes() or 0
  io.stderr:write(string.format("uilarge: 500 MB opened in %.1f ms; worst scroll frame %.1f ms over %d jumps; memory +%.1f MB; %d lines indexed\n",
    topen, worst, n, (mem1 - mem0) / 1048576, (doc.large and select(1, doc.large:count())) or -1))
  if topen > 200 then problems[#problems + 1] = string.format("open took %.0f ms", topen) end
  if worst > 100 then problems[#problems + 1] = string.format("a scroll frame took %.0f ms", worst) end
  os.remove(path)
  for _, p in ipairs(problems) do io.stderr:write("uilarge: ", p, "\n") end
  io.stderr:write("uilarge: ", #problems == 0 and "ok" or "FAILED", "\n")
  os.exit(#problems == 0 and 0 or 1)
  end)
  if not okrun then io.stderr:write("uilarge: script error: ", tostring(why), "\n"); os.exit(2) end
end)
