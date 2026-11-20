-- tests/run_turn_session.lua -- api.run_turn's first turn runs as the session's agent.
--
-- run_turn (the default single-agent entry point) built the session's agent
-- record before the session had a row. For a new conversation sess.id was nil,
-- thread.session_agent raised keying live_recs by it, the pcall swallowed
-- that, and the first turn ran with neither the record's system prompt nor its
-- tool list -- and a half-built record (id nil) left on sess.agent, whose
-- checkpoint saved to no row on every later turn. run_one_turn (the REPL,
-- --headless, -p) had the same bug and creates the row first; run_turn now
-- does the same.
--
-- run_on is stubbed: this is about what run_turn hands it, not the model call.
-- Run: boggart --eval tests/run_turn_session.lua
bog.userdir = os.tmpname() .. "_boggart_run_turn_session"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

bog.new_session()
local S = bog.active_session()
S.model = "claude-test-local"
S.agent = nil
eq(S.id, nil, "a new conversation has no row yet")

local real_run_on = bog.api.run_on
local seen
local function stub(sess, text, _on_text, opts)
  seen = { sess = sess, id = sess.id, opts = opts }
  sess.messages[#sess.messages + 1] = { role = "user", content = text }
  sess.messages[#sess.messages + 1] = { role = "assistant", content = { { type = "text", text = "ok" } } }
  if opts and opts.checkpoint then opts.checkpoint() end
  return sess.messages[#sess.messages], "end_turn"
end
bog.api.run_on = stub
local ok, err = pcall(bog.api.run_turn, "first turn", nil)
bog.api.run_on = real_run_on

ck(ok, "run_turn ran (" .. tostring(err) .. ")")
seen = seen or {}
ck(seen.id ~= nil, "the session has its row before the turn runs")
local rec = S.agent
ck(rec ~= nil and rec.id ~= nil and rec.id == S.id, "the session's agent record has the session's id")
ck(rec ~= nil and seen.opts == rec.opts, "the first turn runs with the agent record's options")
ck(seen.opts and type(seen.opts.system) == "function", "including its system prompt")
ck(seen.opts and type(seen.opts.tools) == "function", "and its tool list")
ck(rec ~= nil and bog.thread.live_recs[S.id] == rec, "the record is registered under the session's id")
local row = S.id and bog.store.sess_load(S.id)
eq(row and #row.messages, 2, "the first turn's checkpoint saved into the session's row")

-- A new conversation (/new) must not keep running as the previous one's agent:
-- its record names the old row, and its checkpoints would write there.
local first_id = S.id
bog.new_session()
S = bog.active_session()
bog.api.run_on = stub
ok, err = pcall(bog.api.run_turn, "second conversation", nil)
bog.api.run_on = real_run_on
ck(ok, "the second conversation's turn ran (" .. tostring(err) .. ")")
ck(S.id ~= nil and S.id ~= first_id, "the second conversation has its own row")
ck(S.agent ~= nil and S.agent.id == S.id, "and runs as its own agent")
local old_row = bog.store.sess_load(first_id)
eq(old_row and #old_row.messages, 2, "the first conversation's row was not written over")
local new_row = S.id and bog.store.sess_load(S.id)
eq(new_row and #new_row.messages, 2, "the second conversation's turn saved into its own row")

if fails == 0 then
  io.write("ok  run_turn_session: the first turn runs as the session's agent, checkpointing into its row\n")
else
  io.write(string.format("FAIL run_turn_session: %d check(s) failed\n", fails))
  os.exit(1)
end
