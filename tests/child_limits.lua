-- tests/child_limits.lua -- a sub-agent runs with its parent's limits.
--
-- A child used to be created with a fixed 16,000-token reply limit, no context
-- window and medium effort, whatever its parent had been told. On a run
-- configured for a 64k local model at high effort, every child then compacted
-- against the wrong window and asked for replies at the wrong length. Children
-- now inherit the parent's context window, reply limit and effort; the spawn
-- call may narrow them, and a child sent to a DIFFERENT model resolves that
-- model's own window and reply limit instead of borrowing numbers that
-- describe another model.
-- Run: boggart --eval tests/child_limits.lua
bog.userdir = os.tmpname() .. "_boggart_child_limits"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()
require("catalog").seed_if_empty()
local thread = require("thread")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

local P = bog.session
P.model, P.route = "claude-opus-5", nil

-- ---- inherited ----------------------------------------------------------------
P.context_limit, P.max_tokens, P.effort = 64000, 12000, "high"
local c = thread.new_agent{ task = "x" }
eq(c.session.context_limit, 64000, "child inherits the context window")
eq(c.session.max_tokens, 12000, "child inherits the reply limit")
eq(c.session.effort, "high", "child inherits the effort")
eq(c.session.token_budget, thread.default_token_budget, "default output budget unchanged")

-- ---- narrowed by the spawn ---------------------------------------------------------
local n = thread.new_agent{ task = "x", effort = "low", budget = 500, max_tokens = 4000, context_limit = 32000 }
eq(n.session.effort, "low", "spawn effort wins")
eq(n.session.token_budget, 500, "spawn budget still sets token_budget")
eq(n.session.max_tokens, 4000, "spawn may lower the reply limit")
eq(n.session.context_limit, 32000, "spawn may lower the context window")
local w = thread.new_agent{ task = "x", max_tokens = 99999, context_limit = 999999 }
eq(w.session.max_tokens, 12000, "spawn cannot raise the reply limit above the parent's")
eq(w.session.context_limit, 64000, "spawn cannot raise the context window above the parent's")

-- ---- a different model resolves its own numbers ---------------------------------------
local o = thread.new_agent{ task = "x", model = "glm-5.3" }
eq(o.session.model, "glm-5.3", "routed to the other model")
eq(o.session.context_limit, nil, "another model's window is not borrowed")
eq(o.session.max_tokens, nil, "another model's reply limit is not borrowed")
eq(o.session.effort, "high", "effort is a level, not a model property: still inherited")

-- ---- a grandchild inherits from its own parent -------------------------------------
c.session.context_limit, c.session.max_tokens, c.session.effort = 48000, 6000, "medium"
local g = thread.new_agent{ task = "x", parent_id = c.id }
eq(g.session.context_limit, 48000, "grandchild inherits its parent's window")
eq(g.session.max_tokens, 6000, "grandchild inherits its parent's reply limit")
eq(g.session.effort, "medium", "grandchild inherits its parent's effort")

-- ---- nothing set: the defaults ----------------------------------------------------
P.context_limit, P.max_tokens, P.effort = nil, nil, nil
local d = thread.new_agent{ task = "x" }
eq(d.session.context_limit, nil, "no parent window: resolved per model at request time")
eq(d.session.max_tokens, nil, "no parent reply limit: resolved per model at request time")
eq(d.session.effort, thread.default_effort, "no parent effort: the default effort")
eq(d.session.compact_at, nil, "the unused compact_at field is gone")

-- ---- the request a child sends --------------------------------------------------
-- What the child inherited must reach the wire: context window and reply
-- limit through the request's max_tokens, effort through reasoning_effort.
P.context_limit, P.max_tokens, P.effort = 64000, 12000, "high"
local k = thread.new_agent{ task = "x" }
local sent
local _, stop = bog.api.run_on(k.session, "hello", nil, {
  stream = function(body, sink)
    sent = body
    return { role = "assistant", content = { { type = "text", text = "ok" } },
             usage = { input_tokens = 50000, output_tokens = 1 } }, "end_turn"
  end,
  system = function() return "" end, tools = function() return {} end })
eq(stop, "end_turn", "child turn ran")
eq(sent and sent.max_tokens, 12000, "the child's request asks for the inherited reply limit")
eq(sent and sent.reasoning_effort, "high", "the child's request carries the inherited effort")

if fails == 0 then
  io.write("ok  child_limits: sub-agents inherit window, reply limit and effort\n")
else
  io.write(string.format("FAIL child_limits: %d check(s) failed\n", fails))
  os.exit(1)
end
