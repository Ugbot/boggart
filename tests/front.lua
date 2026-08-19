-- tests/front.lua -- shared TUI/studio front-end engines: @mentions, !bash
-- parsing, permission wrap, help overlay, slash commands. No tty, no model.
local mention = require("mention")
local take = require("take")
local perm = require("perm")
local help = require("tui.help")
local C = require("complete")

local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end
end

-- ---- mentions --------------------------------------------------------------
local text, notes = mention.expand("see @lua/complete.lua please")
check(type(text) == "string" and text:find("complete.lua", 1, true),
  "@lua/complete.lua expands to an attachment")
check(#notes == 1 and notes[1].ok, "mention note marks the file as attached")
check(text:find("--- lua/complete.lua ---", 1, true), "attachment is fenced with the path")

local miss, n2 = mention.expand("see @no_such_file_zzz")
check(miss == "see @no_such_file_zzz", "missing @file leaves the prompt unchanged")
check(#n2 == 1 and not n2[1].ok, "missing @file is reported")

local uniq = mention.resolve("lua/complete.lua")
check(uniq == "lua/complete.lua",
  "resolve of an exact path returns that path (got " .. tostring(uniq) .. ")")

-- ---- take.parse ------------------------------------------------------------
check(take.parse("").kind == "empty", "blank line is empty")
check(take.parse("  ").kind == "empty", "whitespace is empty")
local bash = take.parse("!echo hi")
check(bash.kind == "bash" and bash.command == "echo hi", "!echo hi is a bash line")
local sl = take.parse("/help")
check(sl.kind == "slash" and sl.line == "/help", "/help is a slash line")
local pr = take.parse("hello")
check(pr.kind == "prompt" and pr.text == "hello", "prose is a prompt")

local okb, out = take.run_bash("echo front-ok")
check(okb and tostring(out):find("front-ok", 1, true),
  "!bash runs through the bash tool (got " .. tostring(out):sub(1, 60) .. ")")

-- ---- permission wrap -------------------------------------------------------
perm.set_mode("chat")
check(perm.policy_for("write") == "deny", "chat mode denies write")
local ran
local deny = perm.wrap_run(function() ran = true; return "ran" end, perm.state())
local msg = deny("write", { path = "x", content = "y" })
check(type(msg) == "string" and msg:find("permission_error", 1, true),
  "wrap_run in chat returns a permission error")
check(not ran, "wrap_run in chat does not call the tool")

perm.set_mode("auto")
ran = nil
local allow = perm.wrap_run(function() ran = true; return "ran" end, perm.state())
check(allow("write", { path = "x", content = "y" }) == "ran" and ran,
  "wrap_run in auto runs the tool")

perm.set_mode("smart")
local rec
local wrapped = perm.wrap_run(function() return "ran" end, perm.state(), {
  on_ask = function(r) rec = r; r.decision = "approve" end,
})
check(wrapped("write", { path = "x", content = "y" }) == "ran",
  "wrap_run in smart asks then runs when approved immediately")
check(rec and rec.name == "write", "on_ask received the write record")

local rejected
local wrap2 = perm.wrap_run(function() rejected = true; return "ran" end, perm.state(), {
  on_ask = function(r) r.decision = "reject" end,
})
local rmsg = wrap2("bash", { command = "rm -rf /" })
check(type(rmsg) == "string" and rmsg:find("rejected", 1, true) and not rejected,
  "wrap_run reject does not run the tool")

-- A parked ask actually yields, so the scheduler can paint the bar.
perm.set_mode("manual")
local parked
local wrap3 = perm.wrap_run(function() return "ran" end, perm.state(), {
  on_ask = function(r) parked = r end,
})
local co = coroutine.create(function() return wrap3("read", {}) end)
local okc, a = coroutine.resume(co)
check(okc and a == "approve" and parked and parked.decision == nil,
  "wrap_run yields 'approve' until the user decides")
parked.decision = "approve"
okc, a = coroutine.resume(co)
check(okc and a == "ran", "wrap_run resumes and runs after approve")

perm.set_mode("smart") -- leave the shared state as the default

-- turn_opts is the shared REPL/cTUI/studio wiring: chat withholds schemas,
-- and wrap_run is installed unless the caller already set run_tool.
perm.set_mode("chat")
local topts = perm.turn_opts()
check(type(topts.tools) == "function" and #(topts.tools()) == 0,
  "turn_opts in chat withholds tool schemas")
check(type(topts.run_tool) == "function", "turn_opts installs wrap_run")
perm.set_mode("smart")
local topts2 = perm.turn_opts({ tools = function() return { "kept" } end })
check(topts2.tools()[1] == "kept", "turn_opts does not overwrite an explicit tools fn")

-- REPL uses the same take.parse door as the TUI and studio.
local mention_line = take.parse("see @lua/complete.lua please")
check(mention_line.kind == "prompt" and mention_line.notes[1] and mention_line.notes[1].ok,
  "REPL @file lines parse as prompts with an attachment")
check(take.parse("!echo hi").kind == "bash", "REPL !bash is not sent to the model")
check(take.parse("/mode chat").kind == "slash", "REPL /mode is a slash command")

-- sched.drive runs a yielding fn from the main thread.
local sched = require("sched")
local drove = 0
check(sched.drive(function() drove = 1; return 7 end) == 7 and drove == 1,
  "sched.drive on a non-yielding fn returns its result")
local inner
check(coroutine.wrap(function()
    return sched.drive(function() inner = true; return 3 end)
  end)() == 3 and inner,
  "sched.drive inside a coroutine just calls through")

-- ---- help overlay ----------------------------------------------------------
check(help.too_small(10, 10), "a 10-col terminal is too small")
check(help.too_small(80, 4), "a 4-row terminal is too small")
check(not help.too_small(80, 24), "80x24 is usable")
local hr = help.runs(80)
check(#hr >= 8 and hr[1][1].text:find("shortcut", 1, true),
  "? overlay starts with a shortcuts header")

-- ---- slash registry --------------------------------------------------------
check(C.map.clear and C.map.compact and C.map.cost and C.map.copy and C.map.mode,
  "registry has /clear /compact /cost /copy /mode")
check(C.help_text():find("/mode", 1, true), "/help lists /mode")

local buf = {}
local real_write, real_print = io.write, print
io.write = function(...)
  for i = 1, select("#", ...) do buf[#buf + 1] = tostring((select(i, ...))) end
end
print = function(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  buf[#buf + 1] = table.concat(t, "\t") .. "\n"
end
bog.handle_command("/mode")
bog.handle_command("/mode chat")
bog.handle_command("/mode")
bog.handle_command("/mode smart")
io.write, print = real_write, real_print
local dumped = table.concat(buf)
check(dumped:find("chat", 1, true) and dumped:find("Smart", 1, true),
  "/mode reports and sets the shared permission mode")
check(perm.state().mode == "smart", "/mode smart restored the default")

if fails > 0 then
  io.write(string.format("%d front-end checks failed\n", fails))
  os.exit(1)
end
io.write("front: all checks passed\n")
