-- supervisor.lua -- the bus control plane (lua/supervisor.lua). Proves control
-- routes through the fabric: a command is a byte record on a work queue, the
-- wake pumps it on the main thread, it drives sched/thread, and every action is
-- an observable ctl:* event. sched/thread are stubbed so no real fleet is needed.
local sup = require("supervisor")
local json = require("json")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- ---- stubs: record what the supervisor drives -----------------------------
local calls = {}
local sched_save, thread_save = bog.sched, bog.thread
bog.sched = {
  actors = { { id = 1 }, { id = 2 }, { id = 3 } },
  pause = function(id, on) calls[#calls + 1] = { "pause", id, on } end,
  kill  = function(id) calls[#calls + 1] = { "kill", id }; return true end,
}
bog.thread = { kill = function(id) calls[#calls + 1] = { "tkill", id }; return true end }

-- observe the ctl:* stream
local seen = {}
local obs = bus.subscribe("ctl:*", function(topic, payload) seen[#seen + 1] = { topic, json.decode(payload) } end)
local function last_ctl() return seen[#seen] end

-- ---- uninstalled: commands still execute (inline pump fallback) ------------
ok(not sup._installed, "starts uninstalled (fresh --eval does not activate agents)")
sup.kill(5)
eq(#calls, 1, "uninstalled: the command executed inline")
eq(calls[1][1], "tkill", "kill routes through the operator kill (tells the parent)")
eq(calls[1][2], 5, "kill carries the id")
ok(last_ctl() and last_ctl()[1] == "ctl:kill", "kill is observable as ctl:kill")

-- ---- install: now the wake drains the queue on the main thread ------------
sup.install()
ok(sup._installed, "install() marks installed")

sup.pause(3, true)
eq(calls[#calls][1] .. calls[#calls][2], "pause3", "installed: pause(3) drives sched.pause")
ok(calls[#calls][3] == true, "pause carries the on flag")

sup.resume(3)
ok(calls[#calls][1] == "pause" and calls[#calls][3] == false, "resume drives sched.pause(id,false)")

-- fleet pause: every actor except the coordinator
calls = {}
sup.pause_fleet(2, true)
eq(#calls, 2, "pause_fleet touches every actor but the excepted one")
local ids = { calls[1][2], calls[2][2] }
ok((ids[1] == 1 or ids[1] == 3) and ids[2] ~= 2, "pause_fleet excepted actor 2")
ok(last_ctl()[1] == "ctl:pause_fleet", "pause_fleet is observable")

-- kill_all: every actor
calls = {}
sup.kill_all()
eq(#calls, 3, "kill_all kills every actor in the fleet")

-- ---- the command channel is an ORDERED work queue -------------------------
calls = {}
bus.push("supervisor.cmd", json.encode{ verb = "pause", id = 10, on = true })
bus.push("supervisor.cmd", json.encode{ verb = "pause", id = 20, on = true })
bus.push("supervisor.cmd", json.encode{ verb = "pause", id = 30, on = true })
local n = sup.pump()
eq(n, 3, "pump drains all queued commands")
ok(calls[1][2] == 10 and calls[2][2] == 20 and calls[3][2] == 30, "commands execute in FIFO order")

-- ---- a malformed command is dropped, not fatal ----------------------------
calls = {}
bus.push("supervisor.cmd", "{ not json")
bus.push("supervisor.cmd", json.encode{ verb = "pause", id = 99, on = false })
sup.pump()
eq(#calls, 1, "a malformed command is skipped; the good one still runs")
eq(calls[1][2], 99, "the well-formed command executed")

-- ---- pool-worker control runs inline (handles don't serialize) -----------
do
  seen = {}
  local w = worker.spawn("while true do end")   -- a runaway to kill
  local oks = pcall(sup.kill_worker, w)          -- must NOT error on the userdata
  ok(oks, "kill_worker does not choke on the (non-serializable) handle")
  ok(last_ctl() and last_ctl()[1] == "ctl:kill_worker", "kill_worker emits an observable ctl:kill_worker")
  local okc = worker.join(w)                      -- must terminate (the kill landed)
  ok(okc == false, "kill_worker actually killed the spinning worker")
end

bus.unsubscribe(obs)
bog.sched, bog.thread = sched_save, thread_save

io.write(failed == 0 and ("supervisor: all " .. passed .. " passed\n")
                      or ("supervisor: " .. failed .. " FAILED, " .. passed .. " passed\n"))
os.exit(failed == 0 and 0 or 1)
