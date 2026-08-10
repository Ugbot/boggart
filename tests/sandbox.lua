-- sandbox.lua -- the capability boundary for generated tools.
--
-- boggart's sandbox is not a Lua sandbox, it is the C/Lua boundary: capability
-- primitives live in C with their policy attached (sys.rmtree refuses "/" and
-- uses lstat; proc.run bounds output and enforces a timeout), and Lua composes
-- them. That boundary is only real if composition cannot step around it.
--
-- It could, until recently. A tool body compiled with a bare load() inherited
-- _G, so io.open, os.remove and -- once libuv was vendored -- uv.spawn and
-- uv.fs_unlink sat next to the guarded sys.* calls with no policy on any of
-- them. Every guard in C was one require("uv") away from irrelevant.
--
-- These tests pin the boundary shut, in-session AND across a restart, which is
-- where the first version of the fix leaked.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_sandbox"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

-- Define a tool whose body is `return tostring(<expr>)`, then call it.
local function probe(expr)
  local r = bog.tools.run("define_tool",
    { name = "probe", description = "env probe", lua = "return tostring(" .. expr .. ")" })
  if r:find("Tool error", 1, true) then return "DEFINE-FAIL: " .. r end
  local okc, out = pcall(bog.tools.run, "probe", {})
  return okc and out or ("raised: " .. tostring(out))
end

-- ---- capabilities must be reachable, or the sandbox is useless ----
for _, c in ipairs({
  { "sys ~= nil",        "true", "sys (C-backed filesystem/process capabilities)" },
  { "sys.exec ~= nil",   "true", "sys.exec (shell, via the bounded proc.run)" },
  { "sys.rmtree ~= nil", "true", "sys.rmtree (guarded delete)" },
  { "db ~= nil",         "true", "db (SQLite)" },
  { "json ~= nil",       "true", "json" },
  { "gold ~= nil",       "true", "gold stdlib" },
  { "tools.call ~= nil", "true", "tools.call (composition)" },
  { "string.rep ~= nil", "true", "string" },
  { "table.concat ~= nil", "true", "table" },
  { "math.floor ~= nil", "true", "math" },
  { "coroutine ~= nil",  "true", "coroutine (proc.run yields through it)" },
  { "os.time() > 0",     "true", "os.time (the harmless half of os)" },
}) do
  eq(probe(c[1]), c[2], "reachable: " .. c[3])
end

-- ---- raw OS and harness infrastructure must NOT be reachable ----
for _, name in ipairs({
  "io",        -- io.open would bypass every path guard
  "os.remove", -- ...as would this
  "os.execute", "os.rename", "os.tmpname",
  "require",   -- require("uv") was the hole that made this file necessary
  "load", "loadfile", "dofile", -- would let a body rebuild an unsandboxed chunk
  "debug",     -- debug.setupvalue can reach into other closures' environments
  "package",   -- package.loaded is a back door to every module
  "uv",        -- raw libuv: spawn, fs_unlink, sockets, no policy at all
  "http", "swarm", "mcp", -- harness transports, not tool vocabulary
  "bog",       -- the whole app context, including bog.db and bog.tools
}) do
  eq(probe(name), "nil", "unreachable: " .. name)
end

-- ---- the guard in C is the one that actually enforces policy ----
eq(probe('select(1, sys.rmtree("/"))'), "nil", "sys.rmtree still refuses / from inside a tool")

-- ---- composition works (paper §7): a tool can call another tool ----
bog.tools.run("define_tool", { name = "adder", description = "adds",
  input_schema = { type = "object", properties = { n = { type = "number" } } },
  lua = "return tostring((args.n or 0) + 1)" })
bog.tools.run("define_tool", { name = "adder2", description = "adds twice",
  lua = 'return tools.call("adder", { n = tonumber(tools.call("adder", { n = 1 })) })' })
eq(bog.tools.run("adder2", {}), "3", "a generated tool can compose another via tools.call")

-- ---- the boundary must survive a restart ------------------------------------
-- The first version of this fix applied the environment only at define time.
-- The persisted file carried its own load() call, so a tool restored on the
-- next run got _G back and the sandbox lasted exactly one session.
bog.tools.run("define_tool", { name = "persisted", description = "d", scope = "global",
  lua = 'return "io=" .. tostring(io) .. ",uv=" .. tostring(uv) .. ",sys=" .. tostring(sys ~= nil)' })
eq(bog.tools.run("persisted", {}), "io=nil,uv=nil,sys=true", "sandboxed when freshly defined")

local file = bog.userdir .. "/lua/tools/persisted.lua"
local src = bog.util.read_file(file)
ok(src ~= nil, "tool was persisted to disk")
ok(src and not src:find("load(", 1, true), "persisted file contains no load() call (data only)")
ok(src and src:find("body =", 1, true) ~= nil, "persisted file stores the body as data")

-- reload the module from scratch: this is what a restart does
package.loaded["tools"] = nil
bog.tools = require("tools")
eq(bog.tools.run("persisted", {}), "io=nil,uv=nil,sys=true", "still sandboxed after reload from disk")

-- ---- a tool file that has grown code cannot execute it ----
-- Loaded with an empty environment, so even a hand-edited file is inert.
bog.util.write_file(bog.userdir .. "/lua/tools/nasty.lua",
  'local x = os.time()\nreturn { description = "d", input_schema = {}, body = "return 1" }\n')
package.loaded["tools"] = nil
bog.tools = require("tools")
ok(bog.tools.registry["nasty"] == nil, "a tool file calling os.* fails to load rather than running")

-- ---- execution limits (paper §16.8) ---------------------------------------
-- Bodies are model-written, and the failure that matters is the boring one: an
-- accidental infinite loop. Since everything shares one libuv loop now, a
-- spinning tool would stall every other agent's token stream behind it.
--
-- The budget is on instructions, not wall clock, and that is deliberate: a tool
-- that shells out to a ten-minute build is legitimate and spends that time
-- yielded, executing nothing. proc.run carries its own timeout for I/O.
bog.tools.run("define_tool", { name = "spin", description = "d", lua = "while true do end" })
local spun = bog.tools.run("spin", {})
ok(spun:find("[timeout]", 1, true) ~= nil, "an infinite loop is stopped, not hung: " .. spun:sub(1, 60))

bog.tools.run("define_tool", { name = "hog", description = "d",
  lua = "local t = {} while true do t[#t+1] = string.rep('x', 100000) end" })
ok(bog.tools.run("hog", {}):find("[resource_limit]", 1, true) ~= nil,
   "runaway allocation is stopped and reported as resource_limit")

-- the hook must not leak onto the harness afterwards
bog.tools.run("define_tool", { name = "quick", description = "d", lua = "return 'ok'" })
eq(bog.tools.run("quick", {}), "ok", "a normal tool still runs after a limit trip")
eq(debug.gethook(), nil, "the instruction hook is cleared after every call")

-- ---- error taxonomy (paper §15) -------------------------------------------
-- One opaque error class leaves the model guessing whether to fix the tool,
-- change the call, or fall back to primitives. Each kind implies a response.
-- %w excludes underscore in Lua patterns, and every kind has one.
local function kind_of(s) return s:match("^Tool error: %[([%w_]+)%]") end
eq(kind_of(bog.tools.run("no_such_tool_xyz", {})), "tool_not_found", "unknown tool")
eq(kind_of(bog.tools.run("read", {})), "validation_error", "missing required argument")
eq(kind_of(bog.tools.run("read", { path = "/no/such/file/here" })), "host_capability_error",
   "a failed host call is not a validation error")
eq(kind_of(bog.tools.run("edit", { path = "x", old = "", new = "y" })), "validation_error",
   "empty 'old' is a validation error")
eq(kind_of(bog.tools.run("define_tool", { name = "nope", description = "d",
   lua = "this is not lua ((" })), "validation_error",
   "an uncompilable body is bad input to define_tool, not a runtime fault")
bog.tools.run("define_tool", { name = "raiser", description = "d", lua = "local t = nil\nreturn t.x" })
eq(kind_of(bog.tools.run("raiser", {})), "runtime_error", "a body that raises is a runtime error")

-- the prefix api.lua tests for must survive the added kind
for _, s2 in ipairs({ bog.tools.run("read", {}), bog.tools.run("no_such_xyz", {}) }) do
  eq(s2:sub(1, 11), "Tool error:", "is_error detection in api.lua still matches")
end

-- ---- oversized results are spilled, not returned (paper §14) --------------
bog.tools.run("define_tool", { name = "flood", description = "d",
  lua = "return string.rep('spam\\n', 400000)" })
local flooded = bog.tools.run("flood", {})
eq(kind_of(flooded), "result_too_large", "an oversized result is classified")
ok(#flooded < 20000, "the oversized result was spilled, not returned inline (" .. #flooded .. " bytes)")
ok(flooded:find("read the saved file", 1, true) ~= nil, "it points at the saved file")

if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
