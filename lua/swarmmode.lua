-- swarm.lua -- the swarm mode entry point. Builds the coordinator (actor #0),
-- wires the swarm tools, and drives the cooperative scheduler either as a
-- one-shot orchestration (`boggart swarm "task"`) or an interactive coordinator
-- REPL (`boggart swarm`). Everything crossing the bus is journalled to SQLite.
local M = {}
local COL = { dim = "\27[2m", tool = "\27[36m", err = "\27[31m", reset = "\27[0m" }

-- Run one coordinator turn (and drain all agents it spawns) to completion.
function M.run_turn(coord, text)
  local first = not coord._titled
  if first then
    coord._titled = true
    bog.store.thread_save(coord.id, { title = text:gsub("%s+", " "):sub(1, 60) })
  end
  local co = coroutine.create(function()
    bog.api.run_on(coord.session, text, function(s) io.write(s); io.flush() end, coord.opts)
  end)
  bog.sched.add(coord.id, co)
  -- ---- --tui: opt-in ltui dashboard (lua/dash.lua) -------------------------
  -- bog.dash is set only when --tui was asked for. dash.start returns the opts
  -- for sched.run, whose should_stop hook paints one frame per scheduler
  -- iteration -- the scheduler keeps the loop, ltui never gets it.
  local live = bog.dash and bog.dash.start(coord)
  local ok, err = pcall(bog.sched.run, live)
  if live then bog.dash.stop() end
  -- --------------------------------------------------------------------------
  io.write("\n")
  if not ok then
    if type(err) == "table" and err.boggart_error then
      io.write(COL.err, tostring(err), COL.reset, "\n")
    else
      io.write(COL.err, "swarm error: ", tostring(err), COL.reset, "\n")
    end
  elseif bog.sched.fatal then
    -- The scheduler stopped the run because a condition would have failed every
    -- agent the same way. It logged one line per agent; print the actionable
    -- explanation once, here, where the user is looking.
    io.write(COL.err, tostring(bog.sched.fatal), COL.reset, "\n")
  end
  -- Computed fleet verdict: count the coordinator's children by recorded status,
  -- independent of whatever the coordinator narrated to stdout. A model can call
  -- a 3-of-14 fan-out "success"; these numbers cannot. (Phase 1's exit contract
  -- makes "done" mean delivered + verified; today it means the child did not
  -- crash. In the REPL the count is cumulative across turns.)
  local total, okc, failed = 0, 0, 0
  for _, r in ipairs(bog.store.thread_list(true)) do
    if r.parent_id == coord.id then
      total = total + 1
      if r.status == "done" then okc = okc + 1
      elseif r.status == "error" or r.status == "killed" then failed = failed + 1 end
    end
  end
  if total > 0 then
    io.write(string.format("%sfleet: %d agent(s) — %d ok, %d failed%s\n",
      failed > 0 and COL.err or COL.dim, total, okc, failed, COL.reset))
    -- The scoreboard: the computed KPIs for this fan-out, so "how good was that"
    -- is a number, not the coordinator's prose.
    if bog.telemetry then
      local k = bog.telemetry.kpis(coord.id)
      if k and (k.agents or 0) > 0 then
        io.write(string.format(
          "%sKPIs: deliverable %.0f%%  false-success %d  tokens/artifact %s  think:output %s%s\n",
          COL.dim, 100 * (k.deliverable_rate or 0), k.false_success or 0,
          k.tokens_per_artifact and string.format("%.0f", k.tokens_per_artifact) or "-",
          k.think_output_ratio and string.format("%.1f", k.think_output_ratio) or "-",
          COL.reset))
      end
    end
  end
  coord._fleet = { total = total, ok = okc, failed = failed }
  bog.store.thread_save(coord.id, { messages = coord.session.messages, status = "idle" })
end

local function print_help()
  io.write([[
swarm commands:
  /help           this help
  /threads        list agents/threads and status
  /journal [n]    show the last n bus messages (default 20)
  /agents         list standard agents you can spawn
  /tui [on|off]   live swarm dashboard while a task runs (same as --tui)
  /model <id>     set the coordinator model
  /quit           exit
Anything else is a task for the coordinator (it will fan out as needed).
]])
end

function M.command(line, coord)
  local cmd, rest = line:match("^/(%S+)%s*(.*)$")
  if cmd == "quit" or cmd == "exit" then return true
  elseif cmd == "help" then print_help()
  elseif cmd == "threads" then
    for _, r in ipairs(bog.store.thread_list(true)) do
      io.write(string.format("  %d  %-7s  %s\n", r.id, r.status or "?", r.title or ""))
    end
  elseif cmd == "journal" then
    local n = tonumber(rest) or 20
    local rows = bog.store.journal_list(n)
    for i = #rows, 1, -1 do
      local r = rows[i]
      local dst = r.to_id and ("->" .. r.to_id) or (r.topic and ("#" .. r.topic) or "")
      io.write(string.format("  %d\t%s %s\t%s\t%s\n", r.id, r.kind or "?", (r.from_id or 0) .. dst,
        r.processed_at and "done" or "pending", (r.payload or ""):gsub("%s+", " "):sub(1, 60)))
    end
  elseif cmd == "agents" then
    io.write("  ", table.concat(bog.agents.list(), ", "), "\n")
  elseif cmd == "tui" then -- --tui, toggled from the REPL
    bog.dash = rest ~= "off" and require("dash") or nil
    io.write("dashboard ", bog.dash and "on (shown while the next task runs)" or "off", "\n")
  elseif cmd == "model" then
    if rest ~= "" then coord.session.model = rest end
    io.write("model = ", coord.session.model, "\n")
  else
    io.write("unknown command: /", tostring(cmd), " (try /help)\n")
  end
  return false
end

function M.repl(coord)
  io.write("boggart swarm  ", bog.version, "  model=", coord.session.model, "  (/help)\n")
  while true do
    local line = sys.readline("\27[1mswarm>\27[0m ")
    if line == nil then io.write("\n"); break end
    if line ~= "" then sys.add_history(line) end
    if line:sub(1, 1) == "/" then
      if M.command(line, coord) then break end
    elseif line:match("%S") then
      M.run_turn(coord, line)
    end
  end
  bog.store.thread_set_status(coord.id, "done")
  return 0
end

function M.run()
  -- The runtime is stood up by bog.activate_agents() (the boot dispatch calls it
  -- before us) -- the same activation the REPL and cTUI use.
  --
  -- --tui only: everything else (REPL, oneshot, --headless) stays plain
  -- linear streaming to stdout. Requiring dash does not load ltui or curses.
  local dash = require("dash")
  if dash.wanted() then bog.dash = dash end

  if boggart.resume then
    local n = swarm.redeliver()
    bog.log(string.format("resume: redelivered %d undelivered message(s) from the journal", n))
  end

  local coord = bog.thread.new_agent{ agent = "coordinator", title = "coordinator", model = bog.session.model }
  bog.swarm_root = coord

  local task = boggart.prompt
  if task and task ~= "" then
    M.run_turn(coord, task)
    -- One-shot exit code reflects the computed fleet verdict: a fan-out where a
    -- child failed is a non-zero exit, so a script/CI can trust the result
    -- without parsing the coordinator's prose.
    local v = coord._fleet
    return (v and v.failed and v.failed > 0) and 1 or 0
  end
  return M.repl(coord)
end

return M
