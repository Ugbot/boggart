-- tests/complete.lua -- the REPL completion engine, exercised with no terminal.
--
-- complete.lua is pure data-in/data-out, so every branch is checkable here: run
-- with `boggart --eval tests/complete.lua`. No tty, no model call. cwd is the
-- repo root under --eval, which the @file cases rely on.
local C = require("complete")

local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end
end

-- Set membership over the {text=...} items complete() returns.
local function texts(items)
  local s = {}
  for _, it in ipairs(items) do s[it.text] = true end
  return s
end
local function has(items, t) return texts(items)[t] == true end
local function count(items) return #items end

-- ---- /help is generated from the registry ----------------------------------
local help = C.help_text()
check(help:find("/model", 1, true), "help lists /model")
check(help:find("/help", 1, true), "help lists /help")
check(help:find("/tools", 1, true), "help lists /tools")
check(help:find("@path", 1, true), "help mentions @path references")

-- ---- the registry is exactly the intended set ------------------------------
local want = { help = true, tools = true, auth = true, doctor = true,
  memory = true, sessions = true, resume = true, reload = true, reset = true,
  trust = true, model = true, endpoint = true, agents = true, ["until"] = true,
  new = true, dispatch = true,
  status = true, diff = true, commit = true, push = true, sync = true, quit = true }
for _, c in ipairs(C.commands) do
  check(want[c.name], "unexpected command in registry: /" .. c.name)
  want[c.name] = nil
end
for name in pairs(want) do check(false, "command missing from registry: /" .. name) end

-- ---- completing the command itself -----------------------------------------
local all = C.complete("/")
check(count(all) == #C.commands, "'/' offers every command (" .. count(all) .. ")")
for _, it in ipairs(all) do
  check(it.text:sub(1, 1) == "/", "command completion '" .. it.text .. "' keeps its slash")
end

local mo = C.complete("/mo")
check(has(mo, "/model"), "'/mo' -> /model")
check(not has(mo, "/tools"), "'/mo' does NOT offer /tools (prefix filter works)")
check(not has(mo, "/memory"), "'/mo' does NOT offer /memory")

-- ---- arguments: a fixed list ------------------------------------------------
local auth_all = C.complete("/auth ")
check(has(auth_all, "key") and has(auth_all, "url") and has(auth_all, "clear"),
  "'/auth ' offers key/url/clear")
local auth_k = C.complete("/auth k")
check(has(auth_k, "key") and count(auth_k) == 1, "'/auth k' -> only key")

-- ---- arguments: dynamic sources (must not crash; empty is acceptable) -------
local models = C.complete("/model ")
check(type(models) == "table", "'/model ' returns a list")
check(has(models, "claude-opus-5"), "'/model ' offers a known provider model")
for _, it in ipairs(models) do check(type(it.text) == "string", "model item is a string") end

local sessions = C.complete("/resume ")
check(type(sessions) == "table", "'/resume ' returns a list (may be empty)")

-- A command with no args offers nothing rather than erroring.
check(count(C.complete("/doctor ")) == 0, "'/doctor ' has no argument completions")

-- ---- free prose is left alone ----------------------------------------------
check(count(C.complete("hello there")) == 0, "free prose offers no completion")
check(count(C.complete("write a novel")) == 0, "free prose (2) offers nothing")

-- ---- @file references, in an argument and mid-prose ------------------------
local f = C.complete("@lua/comp")
check(has(f, "@lua/complete.lua"), "'@lua/comp' -> @lua/complete.lua")
local mid = C.complete("tell me about @lua/ap")
check(has(mid, "@lua/api.lua"), "mid-prose '@lua/ap' -> @lua/api.lua")
local dir = C.complete("@lu")
check(has(dir, "@lua/"), "'@lu' -> @lua/ (directory gets a trailing slash)")

-- ---- report -----------------------------------------------------------------
if fails == 0 then
  io.write("ok  complete: all assertions passed\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails))
  os.exit(1)
end
