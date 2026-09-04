-- triggers.lua -- what starts work when nobody is typing.
--
-- The autonomy gap in one sentence: boggart ran to quiescence and exited, so
-- every turn began with a human. A trigger names an occasion -- every N
-- seconds, a clock time, or an event (which includes any webhook that arrived
-- through the C listener) -- and says what to do about it.
--
-- tick() takes `now` so the schedule can be tested without waiting for the
-- clock; the single uv timer that calls it in production is the only part these
-- tests do not exercise, and it is three lines.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_triggers"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local T = require "triggers"

-- ---- the table -----------------------------------------------------------
local t = T.add("nightly", { at = "09:00" }, "summarise yesterday")
eq(t.name, "nightly", "a trigger is added under its name")
ok(t.enabled, "a new trigger is enabled")
ok(t.next_at and t.next_at > os.time(), "a clock trigger is scheduled ahead")
eq(#T.status(), 1, "status lists it")

-- adding the same name replaces rather than stacks
T.add("nightly", { at = "10:00" }, "something else")
eq(#T.status(), 1, "re-adding a name replaces it")
eq(T.list["nightly"].run, "something else", "and takes the new body")

ok(T.remove("nightly"), "remove reports what it removed")
eq(T.remove("nightly"), false, "removing twice is honest about it")

-- ---- clock arithmetic ----------------------------------------------------
-- 09:00 tomorrow when it is already past 09:00 today, 09:00 today when it is not.
local noon = os.time({ year = 2026, month = 9, day = 4, hour = 12, min = 0, sec = 0 })
local nxt = T.next_clock_time("09:00", noon)
ok(nxt > noon, "a clock time already past today rolls to tomorrow")
ok(nxt - noon > 20 * 3600 and nxt - noon < 22 * 3600, "and lands about 21 hours out")
local morning = os.time({ year = 2026, month = 9, day = 4, hour = 6, min = 0, sec = 0 })
local soon = T.next_clock_time("09:00", morning)
eq(soon - morning, 3 * 3600, "a clock time still ahead today is today")
eq(T.next_clock_time("nonsense"), nil, "an unparseable time is nil, not a crash")

-- ---- interval firing -----------------------------------------------------
local fires = 0
T.add("poll", { every = 60 }, function() fires = fires + 1 end)
local base = os.time()
eq(T.tick(base), 0, "nothing fires before it is due")
eq(T.tick(base + 61), 1, "the interval fires when due")
eq(fires, 1, "and the body ran")
eq(T.tick(base + 61), 0, "it does not re-fire in the same second")
eq(T.tick(base + 130), 1, "it fires again one interval later")
eq(fires, 2, "twice in total")

-- disabled triggers keep their place but do not run
T.enable("poll", false)
eq(T.tick(base + 300), 0, "a disabled trigger does not fire")
eq(fires, 2, "and its body did not run")
T.enable("poll", true)
eq(T.tick(base + 400), 1, "re-enabling brings it back")
T.remove("poll")

-- ---- event binding: this is what a webhook becomes -----------------------
local got = nil
T.add("on-push", { on = "hook:push" }, function(ctx) got = ctx end)
bog.events.emit("hook:push", { ref = "refs/heads/main" })
ok(got ~= nil, "an event-bound trigger fires on its event")
eq(got and got.event, "hook:push", "the trigger knows which event woke it")
eq(got and got.data and got.data.ref, "refs/heads/main", "the payload reaches the trigger")
eq(T.list["on-push"].fired, 1, "the firing is counted")

-- removing it unbinds the handler: a stale trigger must not keep firing
T.remove("on-push")
got = nil
bog.events.emit("hook:push", { ref = "x" })
eq(got, nil, "a removed trigger is really unbound")

-- ---- a string body queues a turn rather than running one inline ----------
-- A timer callback is not a place to spend minutes, so firing emits the same
-- prompt event a webhook or a human would.
local queued = nil
local h = bog.events.on("serve:prompt", function(_, ev) queued = ev end)
T.add("daily-report", { every = 10 }, "write the daily report")
T.fire("daily-report")
ok(queued ~= nil, "a string body queues a prompt")
eq(queued and queued.text, "write the daily report", "with the trigger's text")
eq(queued and queued.source, "trigger:daily-report", "labelled with its origin")
bog.events.off(h)

-- ---- persistence ---------------------------------------------------------
-- Schedules must survive a restart; function bodies cannot be serialised and
-- are honestly dropped rather than half-saved.
T.add("with-fn", { every = 30 }, function() end)
T.save()
local before = #T.status()
ok(before >= 2, "two triggers before the reload")
T.list = {}
eq(#T.status(), 0, "table cleared")
local n = T.load()
eq(n, 1, "only the string-bodied trigger came back")
ok(T.list["daily-report"] ~= nil, "and it is the right one")
eq(T.list["daily-report"].run, "write the daily report", "with its body intact")
ok(T.list["with-fn"] == nil, "the function-bodied one was not resurrected wrongly")

-- ---- firing an unknown trigger is a no-op, not an error ------------------
eq(T.fire("nope"), false, "firing an unknown trigger returns false")

io.write(string.format("triggers: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
