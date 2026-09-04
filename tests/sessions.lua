-- sessions.lua -- a conversation nobody had must not leave a row behind.
--
-- Opening boggart, or pressing "new session", or starting the service, used to
-- INSERT a session row immediately -- so every launch left a titleless,
-- messageless entry in the store whether or not anyone typed anything, and the
-- recents list filled with nothing. The row is now created the moment there is
-- something to put in it.
--
-- Both halves matter and both are tested here: nothing is stored for a
-- conversation that never happened, and a conversation that DID happen is
-- stored exactly as before.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_sessions"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local function count()
  return bog.db:query("SELECT COUNT(*) AS c FROM sessions")[1].c
end

eq(count(), 0, "a fresh store has no sessions")

-- ---- doing nothing stores nothing ----------------------------------------
bog.new_session()
eq(count(), 0, "starting a new session writes no row")
eq(bog.active_session().id, nil, "and the session has no id yet")

for _ = 1, 5 do bog.new_session() end
eq(count(), 0, "five new sessions in a row still write nothing")

-- saving an empty session must not resurrect it either: this is the path a
-- front end takes when it closes, and it is how empty rows came back
bog.save_session()
eq(count(), 0, "saving an empty session stores nothing")

-- ---- a turn is what makes a session real ---------------------------------
local S = bog.active_session()
S.messages = {}
local mock = function(_body, sink)
  if sink then sink("hi") end
  return { role = "assistant", content = { { type = "text", text = "hi" } },
           usage = { output_tokens = 1 } }, "end_turn"
end
bog.api.run_on(S, "hello", nil, {
  stream = mock, system = function() return "" end, tools = function() return {} end })

eq(count(), 1, "a turn creates exactly one row")
ok(S.id ~= nil, "and the session now has an id")

bog.save_session()
eq(count(), 1, "saving it does not create a second")
local row = bog.store.sess_load(S.id)
ok(row ~= nil, "the row is loadable")
ok(row and #row.messages >= 2, "and carries the conversation (" ..
   tostring(row and #row.messages) .. " messages)")

-- ---- ensure_session is idempotent ----------------------------------------
local id = S.id
eq(bog.ensure_session(S), id, "ensure_session returns the existing id")
eq(count(), 1, "and creates nothing new")

-- ---- a second conversation is a second row -------------------------------
bog.new_session()
eq(count(), 1, "starting the next one writes nothing yet")
local S2 = bog.active_session()
bog.api.run_on(S2, "second", nil, {
  stream = mock, system = function() return "" end, tools = function() return {} end })
eq(count(), 2, "the second turn creates the second row")
ok(S2.id ~= id, "with its own id")
bog.save_session()   -- what every front end does at the end of a turn

-- ---- what the user typed is kept even when the turn fails ----------------
-- The row is created when a turn STARTS, which is correct: typing a prompt is
-- doing something. The transcript must therefore already hold that prompt
-- before the model is reached, so a turn that errors still saves a real
-- conversation rather than an empty row.
bog.new_session()
local S3 = bog.active_session()
local boom = function() error("the endpoint is unreachable") end
pcall(bog.api.run_on, S3, "a question that never gets answered", nil, {
  stream = boom, system = function() return "" end, tools = function() return {} end })
ok(S3.id ~= nil, "a failed turn still has a session")
ok(#S3.messages > 0, "and the transcript holds what the user typed")
bog.save_session()
local failed_row = bog.store.sess_load(S3.id)
ok(failed_row and #failed_row.messages > 0,
   "so the saved row is a real conversation, not a blank")

-- ---- the listing has no blanks in it -------------------------------------
local list = bog.store.sess_list(50)
eq(#list, 3, "the recents list holds exactly the real conversations")
for _, sr in ipairs(list) do
  local full = bog.store.sess_load(sr.id)
  ok(full and #full.messages > 0, "session " .. sr.id .. " is not empty")
end

-- ---- sweeping up what the old behaviour left behind ----------------------
-- Existing stores are full of blank rows. Removing one loses nothing (no
-- title, no transcript, no lineage), which is what makes an unattended sweep
-- defensible -- but it must leave anything with a word in it, and anything an
-- agent is using, strictly alone.
local before_prune = count()
for _ = 1, 4 do bog.store.sess_create(nil, "m") end          -- blanks, as the old code made
local titled = bog.store.sess_create("titled but never sent", "m")
local child = bog.store.thread_create{ parent_id = id, title = "worker", status = "done" }
local live = bog.store.thread_create{ title = "live agent", status = "running" }
eq(count(), before_prune + 7, "seven more rows, four of them blank")

local removed = bog.store.prune_empty_sessions()
eq(removed, 4, "prune removes exactly the blank ones")
eq(count(), before_prune + 3, "and leaves the rest")
ok(bog.store.sess_load(titled) ~= nil, "a titled session survives, empty or not")
ok(bog.store.sess_load(child) ~= nil, "an agent's thread survives (it has a parent)")
ok(bog.store.sess_load(live) ~= nil, "a running agent survives")
eq(bog.store.prune_empty_sessions(), 0, "pruning again finds nothing")

io.write(string.format("sessions: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
