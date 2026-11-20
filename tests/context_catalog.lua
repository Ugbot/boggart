-- tests/context_catalog.lua -- the context window comes from the model catalog.
--
-- Precedence: the session's own setting, then the catalog's window for the
-- model, then the built-in M.CONTEXT table, then the 200k default. A served
-- request still proves the window is at least that big and raises the
-- assumption.
-- Run: boggart --eval tests/context_catalog.lua
bog.store.open()

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

local api = bog.api

require("catalog").import({
  providers = { ctxtest = { url = "http://127.0.0.1:9", wire = "anthropic" } },
  models = {
    ["ctx-131k-model"] = { provider = "ctxtest", context = 131072 },
    ["ctx-32k-model"]  = { provider = "ctxtest", context = 32768 },
    ["ctx-unknown-window"] = { provider = "ctxtest" },
  },
}, "test")

local function limit(t) t.messages = t.messages or {}; return api.context_limit(t) end

-- ---- precedence ---------------------------------------------------------------
ck(limit{ model = "ctx-131k-model" } == 131072,
   "the catalog's window for the model (got " .. limit{ model = "ctx-131k-model" } .. ")")
ck(limit{ model = "ctx-131k-model", context_limit = 50000 } == 50000,
   "a session setting beats the catalog")
ck(limit{ model = "ctx-unknown-window" } == api.CONTEXT.default,
   "a catalogued model with no window falls back to the default")
ck(limit{ model = "deepseek-v4-flash" } == api.CONTEXT["deepseek-v4-flash"],
   "an uncatalogued model in M.CONTEXT uses it")
ck(limit{ model = "nobody-has-heard-of-this" } == api.CONTEXT.default, "anything else: the default")

-- The shipped catalog knows current Claude windows; M.CONTEXT's 200k is only a
-- fallback for a store without the catalog.
local opus = require("catalog").model("claude-opus-5")
if opus and tonumber(opus.context) then
  ck(limit{ model = "claude-opus-5" } == tonumber(opus.context),
     string.format("claude-opus-5 uses the catalog's window %s (got %d)", opus.context, limit{ model = "claude-opus-5" }))
end

-- The model the turn actually went to (its resolved route) is the one whose
-- window counts, when it differs from the session's own.
ck(limit{ model = "ctx-131k-model", resolved_route = { model = "ctx-32k-model" } } == 32768,
   "the resolved route's model decides the window")

-- A route passed explicitly (e.g. the compaction route) asks for that model's
-- window; the session's own model is the default.
do
  local s = { model = "ctx-131k-model", messages = {} }
  ck(api.context_limit(s, { model = "ctx-32k-model" }) == 32768, "context_limit(sess, route) uses the route's model")
  ck(api.context_limit(s, { model = "ctx-131k-model" }) == 131072, "...and the same model gives the session's window")
  local o = { model = "ctx-131k-model", context_limit = 40000, messages = {} }
  ck(api.context_limit(o, { model = "ctx-131k-model" }) == 40000, "the session override holds for its own model")
  ck(api.context_limit(o, { model = "ctx-32k-model" }) == 32768,
     "...but not for a different model (the override describes the session's model)")
end

-- ---- the served-request adjustment is kept --------------------------------------
do
  local function mock(_, sink)
    if sink then sink("ok") end
    return { role = "assistant", content = { { type = "text", text = "ok" } },
             usage = { input_tokens = 140000, output_tokens = 2 } }, "end_turn"
  end
  local s = { id = 951, model = "ctx-131k-model", messages = {}, compact_ratio = 0.99 }
  local _, stop = api.run_on(s, "hi", nil, { stream = mock,
    system = function() return "" end, tools = function() return {} end })
  ck(stop == "end_turn", "turn ran (" .. tostring(stop) .. ")")
  ck(s.context_limit == math.floor(140000 * 1.25),
     "a served 140k request raises a 131k catalog window (got " .. tostring(s.context_limit) .. ")")
end

if fails == 0 then
  io.write("ok  context_catalog: session > catalog > M.CONTEXT > default\n")
else
  io.write(string.format("FAIL context_catalog: %d check(s) failed\n", fails))
  os.exit(1)
end
