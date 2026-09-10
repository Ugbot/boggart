-- callable.lua -- the GameObject/Component model for skills and tools.
local callable = require("callable")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- ---- a node is callable -----------------------------------------------------
do
  local n = callable.new({ name = "double", run = function(a) return a * 2 end })
  ok(callable.is(n), "new returns a callable")
  ok(n(21) == 42, "invoking runs the body")
end

-- ---- before short-circuits the body (the zero-turn win) ---------------------
do
  local ran_body = false
  local n = callable.new({
    before = function(ctx)
      if ctx.args == 0 then return { done = "empty" } end
    end,
    run = function(a) ran_body = true; return a end,
  })
  ok(n(0) == "empty", "before { done } short-circuits")
  ok(not ran_body, "the body never ran when before answered")
  ran_body = false
  ok(n(5) == 5 and ran_body, "before nil falls through to the body")
end

-- ---- before { set } threads facts into ctx ----------------------------------
do
  local n = callable.new({
    before = function() return { set = { extra = 7 } } end,
    run = function(a, ctx) return a + ctx.extra end,
  })
  ok(n(3) == 10, "before { set } threads context to run")
end

-- ---- finally always runs, sees the result, can rewrite ----------------------
do
  local trail = {}
  local n = callable.new({
    run = function(a) return a end,
    finally = function(ctx, res, err)
      trail[#trail + 1] = "finally"
      return res .. "!"
    end,
  })
  ok(n("x") == "x!", "finally can rewrite the result")
  ok(#trail == 1, "finally ran once")
end

do -- finally runs even when the body raises
  local saw_err
  local n = callable.new({
    run = function() error("boom", 0) end,
    finally = function(ctx, res, err) saw_err = err end,
  })
  local caught = select(2, pcall(n, {}))
  ok(saw_err == "boom", "finally sees the error")
  ok(tostring(caught):find("boom", 1, true) ~= nil, "the error re-raises after finally")
end

-- ---- components: attach, get, send ------------------------------------------
do
  local n = callable.new({ name = "svc" })
  n:attach({ name = "cache", hits = 0, before = function() end,
             bump = function(self) self.hits = self.hits + 1 end })
  n:attach({ name = "core", run = function(a) return a end })
  ok(n:get("cache") ~= nil, "get finds an attached component (GetComponent)")
  ok(n:get("nope") == nil, "get misses cleanly")
  n:send("bump")
  ok(n:get("cache").hits == 1, "send calls a message on components (SendMessage)")
  ok(n(9) == 9, "the first component with a run produces the value")
end

do -- finally ordering is reverse of attach (teardown mirrors setup)
  local order = {}
  local n = callable.new({ name = "e" })
  n:attach({ name = "a", finally = function() order[#order+1] = "a" end })
  n:attach({ name = "b", finally = function() order[#order+1] = "b" end })
  n({})
  ok(order[1] == "b" and order[2] == "a", "finally runs in reverse attach order")
end

-- ---- composition: chain and first -------------------------------------------
do
  local inc = function(a) return a + 1 end
  local pipe = callable.chain(inc, inc, inc)
  ok(pipe(0) == 3, "chain threads results left to right")

  local a = callable.new({ run = function() return nil end })      -- miss
  local b = callable.new({ run = function() return "Tool error: x" end }) -- miss
  local c = callable.new({ run = function() return "hit" end })
  ok(callable.first(a, b, c)({}) == "hit", "first skips nil and error, takes the hit")
end

-- ---- then_ and catch --------------------------------------------------------
do
  local boom = callable.new({ run = function() error("nope", 0) end })
  local safe = boom:catch(function(err) return "caught:" .. err end)
  ok(safe({}) == "caught:nope", "catch intercepts a raise")
end

-- ---- loop with a code stop-evaluation ---------------------------------------
do
  local passes = 0
  local body = callable.new({ run = function(n) passes = passes + 1; return n + 1 end })
  local counted = callable.loop({ body = body, until_ = function(ctx) return ctx.last >= 5 end, max = 100 })
  ok(counted(0) == 5, "loop runs until the code stop-evaluation passes")
  ok(passes == 5, "loop ran exactly to the stop condition")
  local capped = callable.loop({ body = callable.new({ run = function(n) return n + 1 end }),
    until_ = function() return false end, max = 3 })
  ok(capped(0) == 3, "loop honors max as the runaway backstop")
end

-- ---- cond routes with code, only the chosen branch evaluates ----------------
do
  local evaluated
  local n = callable.cond({
    { function(x) return x < 0 end, function() evaluated = "neg"; return "negative" end },
    { function(x) return x == 0 end, function() evaluated = "zero"; return "zero" end },
    { function() evaluated = "pos"; return "positive" end },
  })
  ok(n(-3) == "negative" and evaluated == "neg", "cond takes the first passing branch")
  ok(n(0) == "zero", "cond second branch")
  ok(n(9) == "positive", "cond else branch")
end

-- ---- model as eval, with an injected evaluator ------------------------------
do
  local m = callable.model({ prompt = function(a) return "judge: " .. a end,
    evaluator = function(prompt) return "EVAL[" .. prompt .. "]" end })
  ok(m("x") == "EVAL[judge: x]", "model node calls the evaluator (eval primitive)")
end

-- ---- verify: a code contract over a result ----------------------------------
do
  local tool = callable.new({ run = function(a) return a end })
  local checked = callable.verify(tool, function(ctx) return ctx.result == "good" or "not good" end)
  ok(checked("good") == "good", "verify passes a real result through")
  local err = select(2, pcall(checked, "bad"))
  ok(tostring(err):find("verify failed: not good", 1, true) ~= nil, "verify raises with the reason")
end

-- ---- retry: re-drive with code until it verifies ----------------------------
do
  local n = 0
  local flaky = callable.new({ run = function() n = n + 1; return n end })
  local solid = callable.retry({ node = flaky, check = function(ctx) return ctx.result >= 3 end, max = 5 })
  ok(solid({}) == 3, "retry re-drives until the verifier passes")
  local always = callable.new({ run = function() error("nope", 0) end })
  local giveup = select(2, pcall(callable.retry({ node = always, max = 2 }), {}))
  ok(tostring(giveup):find("nope", 1, true) ~= nil, "retry raises the last error when exhausted")
end

io.write(string.format("callable: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
