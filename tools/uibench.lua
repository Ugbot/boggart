-- uibench.lua -- the frame-rate invariants, as a test that can fail.
--
-- Run with `ninja ui-bench`. Not a ctest: it needs a window server.
--
-- These are not micro-benchmarks and the numbers are not the point. Each one
-- guards a property that, if it broke, would turn a smooth window into a
-- stuttering one -- and would do it silently, because a UI that is too slow
-- still looks correct in a screenshot.
--
-- The budgets are deliberately several times the measured cost. A machine
-- under load should not fail this; a change that makes drawing proportional to
-- transcript length should.
--
-- Expect "exhausted command buffer" warnings while this runs. Calling draw()
-- thirty times without the frame loop in between fills the render cache, which
-- never happens in normal use because a frame flushes it. The warnings are the
-- benchmark's own doing and the timings are unaffected -- the work is still
-- done, the commands are just dropped rather than replayed.
local core = require "core"
local studio = require "core.studio"
local style = require "core.style"
local ui = require "core.ui"

local problems = {}
local function check(ok, msg) if not ok then problems[#problems + 1] = msg end end
local results = {}
local function note(...) results[#results + 1] = string.format(...) end

core.add_thread(function()
  local ok, err = pcall(function()
    coroutine.yield(0.3)
    local v = studio.open_agent()
    core.set_active_view(v)

    local function fill(n)
      v.entries = {}
      for i = 1, n do
        if i % 3 == 0 then
          v:push("assistant", "```lua\nlocal x = " .. i
            .. "\nfor j = 1, 10 do print(j) end\n```")
        else
          v:push("assistant", "Entry " .. i .. " with **bold**, `code`, *italic* "
            .. "and a [link](http://x), long enough to wrap more than once.")
        end
      end
      for _ = 1, 3 do coroutine.yield(0.05) end   -- a real frame warms the cache
    end

    local function time_draw(n)
      local t0 = system.get_time()
      for _ = 1, n do v:draw() end
      return (system.get_time() - t0) / n * 1000
    end

    -- ---- 1. drawing is bounded by the viewport, not the transcript ---------
    --
    -- The property that matters most. A transcript grows without limit; a
    -- window does not. If drawing ever becomes proportional to the number of
    -- entries, a long session degrades until it is unusable, and it does it
    -- gradually enough that nobody files a bug.
    fill(100)
    local small = time_draw(30)
    fill(1600)
    local big = time_draw(30)
    note("draw: %.2f ms at 100 entries, %.2f ms at 1600 (%.1fx for 16x the text)",
      small, big, big / math.max(small, 1e-6))
    check(big < small * 4,
      string.format("drawing scales with the transcript: %.2f ms -> %.2f ms "
        .. "for 16x the entries", small, big))
    check(big < 8.0,
      string.format("a frame costs %.2f ms of a 16.6 ms budget at 1600 entries", big))

    -- ---- 2. the layout cache actually caches ------------------------------
    --
    -- agentview.lua keys its per-entry layout on (columns, text length). If
    -- that key ever stops matching -- a stray field, a width recomputed
    -- differently -- every entry re-wraps on every frame and nothing else in
    -- this file will notice, because the output is identical.
    local t0 = system.get_time()
    for _, e in ipairs(v.entries) do e._layout = nil end
    for _, e in ipairs(v.entries) do v:layout(e, 96) end
    local cold = (system.get_time() - t0) * 1000
    local t1 = system.get_time()
    for _, e in ipairs(v.entries) do v:layout(e, 96) end
    local warm = (system.get_time() - t1) * 1000
    note("layout 1600 entries: cold %.1f ms, warm %.2f ms (%.0fx)",
      cold, warm, cold / math.max(warm, 1e-9))
    check(warm * 20 < cold,
      string.format("the layout cache is not caching: cold %.1f ms, warm %.1f ms",
        cold, warm))

    -- ---- 3. streaming does not re-lay-out the whole transcript ------------
    --
    -- A reply arrives a few characters at a time. Only the entry being
    -- streamed may re-wrap; if appending to the last entry invalidates the
    -- others, every keystroke of the model's output costs a full re-layout.
    v.entries = {}
    for i = 1, 400 do v:push("assistant", "settled entry " .. i) end
    v:draw()
    local cached = 0
    for _, e in ipairs(v.entries) do if e._layout then cached = cached + 1 end end
    v:stream("a chunk arriving")
    v:draw()
    local still = 0
    for i = 1, 400 do if v.entries[i]._layout then still = still + 1 end end
    note("streaming: %d of %d settled layouts survived a chunk", still, cached)
    check(still == cached,
      string.format("a streamed chunk invalidated %d settled layouts",
        cached - still))

    -- ---- 4. style resolution is free --------------------------------------
    --
    -- ui.derive is only cheap if callers pass constant override tables. This
    -- checks the mechanism itself: the same pair must return the identical
    -- table, or a draw loop allocates once per frame per widget.
    local a = ui.derive(ui.styles.button, ui.styles.button_hover)
    local b = ui.derive(ui.styles.button, ui.styles.button_hover)
    check(a == b, "ui.derive does not return a stable table for a stable pair")
    local t2 = system.get_time()
    for _ = 1, 100000 do ui.derive(ui.styles.button, ui.styles.button_active) end
    local per = (system.get_time() - t2) * 1e9 / 100000
    note("ui.derive: %.0f ns per call when cached", per)
    check(per < 1000, string.format("ui.derive costs %.0f ns per call", per))

    -- ---- 5. metrics are computed once -------------------------------------
    local m1 = ui.metrics(style.code_font)
    local m2 = ui.metrics(style.code_font)
    check(m1 == m2, "ui.metrics recomputes on every call")
    check(m1.char_width > 0 and m1.line_height > m1.height,
      "ui.metrics returned nonsense")
  end)

  io.write("\n")
  for _, line in ipairs(results) do io.write("  " .. line .. "\n") end
  if not ok then
    io.write("FAIL  the benchmark itself raised: " .. tostring(err) .. "\n")
    io.flush()
    os.exit(1)
  end
  if #problems > 0 then
    io.write("FAIL\n")
    for _, p in ipairs(problems) do io.write("  - " .. p .. "\n") end
    io.flush()
    os.exit(1)
  end
  io.write("ok  frame-rate invariants hold\n")
  io.flush()
  os.exit(0)
end)
