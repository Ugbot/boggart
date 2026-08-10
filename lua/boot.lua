-- boot.lua -- entry point run by the C core. Installs the overlay module
-- system, builds the `bog` app context, wires the harness, and dispatches on
-- boggart.mode. Everything here is itself overlay-able: edit ~/.boggart/lua/
-- boot.lua and restart, or edit the other modules and call reload.

-- Install the embedded-module fallback searcher FIRST, so require() can find
-- our baked-in modules (strict, json, ...) before anything else runs. The
-- userdir overlay is prepended to package.path a bit later, once bog exists.
table.insert(package.searchers, function(name)
  local src = boggart.embedded((name:gsub("%.", "/")))
  if not src then return "\n\tno embedded module '" .. name .. "'" end
  local chunk, err = load(src, "@embedded:" .. name)
  if not chunk then error(err) end
  return chunk
end)

local strict = require("strict")

-- ---- app context ----------------------------------------------------------
-- Declared as a real global (strict-friendly) so every module can reach it.
global{ bog = {} }
bog.version = boggart.version
bog.userdir = sys.home() .. "/.boggart"
bog.mode = boggart.mode
bog.session = {
  model = boggart.model or "claude-opus-5",
  messages = {},
  max_tokens = 16000,
  compact_at = 400000,
}

-- ---- logging (kept tiny; ds4/lite both keep this modest) ------------------
local COL = { dim = "\27[2m", tool = "\27[36m", err = "\27[31m", reset = "\27[0m" }
local function isatty() return true end -- best-effort; ANSI is harmless if piped
function bog.log(msg)
  io.stderr:write(COL.dim, "· ", tostring(msg), COL.reset, "\n")
end
function bog.log_tool(name, input)
  -- one-line semantic preview of the call (ds4's two-layer idea, minimal form)
  local preview = ""
  if type(input) == "table" then
    local hint = input.command or input.path or input.query or input.name or input.title
    if hint then preview = ": " .. tostring(hint):gsub("\n", " "):sub(1, 80) end
  end
  io.write("\n", COL.tool, "» ", name, preview, COL.reset, "\n")
  io.flush()
end

-- ---- overlay module system -----------------------------------------------
-- Highest priority: ~/.boggart/lua/?.lua (the model's / user's edits). The
-- embedded fallback searcher was installed at the top of this file.
package.path = bog.userdir .. "/lua/?.lua;" .. bog.userdir .. "/lua/?/init.lua;" .. package.path

-- sys.exec used to be a fork/execl/poll/waitpid implementation in C. It is now
-- lua/proc.lua on the libuv loop: portable to Windows, and able to yield to the
-- cooperative scheduler instead of freezing it. Installed here under the old
-- name so every existing caller (api.lua's auth probe, gold.sh, the tests) is
-- unchanged, and lazily so a run that never shells out does not pay for
-- creating the loop.
--
-- Same contract as before: { out = <stdout+stderr>, code, timed_out, truncated }.
function sys.exec(cmd, timeout_sec)
  return require("proc").run(cmd, timeout_sec)
end

-- Universal error funnel (from lite's core.try): returns (ok, result_or_err)
-- and never lets a failure unwind past the caller.
function bog.try(fn, ...)
  local err
  local ok, res = xpcall(fn, function(msg)
    err = tostring(msg) .. "\n" .. debug.traceback(nil, 2)
    return err
  end, ...)
  if ok then return true, res end
  return false, err
end

-- ---- wiring & hot reload ---------------------------------------------------
local CORE = { "json", "util", "store", "memory", "mcphost", "prompt", "tools", "api" }

local function wire()
  for _, m in ipairs(CORE) do package.loaded[m] = nil end
  bog.json = require("json")
  bog.util = require("util")
  bog.store = require("store")
  bog.memory = require("memory")
  bog.mcphost = require("mcphost")
  bog.prompt = require("prompt")
  bog.tools = require("tools")
  bog.api = require("api")
end

-- Session lifecycle (persisted in the SQLite store; bog.db survives reloads).
function bog.new_session()
  local S = bog.session
  S.messages = {}
  S.title = nil
  S.id = bog.store.sess_create(nil, S.model)
end
function bog.save_session()
  local S = bog.session
  if S.id then bog.store.sess_save(S.id, S.title, S.model, S.messages) end
end
function bog.resume_session(id)
  local s = bog.store.sess_load(id)
  if not s then return false end
  local S = bog.session
  S.id = s.id
  S.title = s.title
  S.model = s.model or S.model
  S.messages = s.messages or {}
  return true
end

function bog.reload()
  local snap, snap_loaded = {}, {}
  for _, m in ipairs(CORE) do snap[m] = bog[m]; snap_loaded[m] = package.loaded[m] end
  local ok, err = bog.try(wire)
  if not ok then
    -- restore BOTH bog.* and package.loaded so "old code kept" is fully true
    for _, m in ipairs(CORE) do bog[m] = snap[m]; package.loaded[m] = snap_loaded[m] end
    return false, err
  end
  return true
end

-- ---- modes that don't need the API/harness --------------------------------
local function do_init()
  local dir = bog.userdir .. "/lua"
  sys.mkdir_p(dir)
  local n = 0
  for _, name in ipairs(boggart.embedded_names()) do
    local src = boggart.embedded(name)
    local target = dir .. "/" .. name .. ".lua"
    local sub = target:match("^(.*)/[^/]+$")
    if sub then sys.mkdir_p(sub) end
    if sys.stat(target) == "file" then
      io.write("kept existing ", target, "\n")
    else
      bog.util = bog.util or require("util")
      bog.util.write_file(target, src)
      io.write("wrote ", target, "\n")
      n = n + 1
    end
  end
  io.write(string.format("boggart init: %d files materialized under %s\n", n, dir))
  return 0
end

local function do_reset()
  local target = boggart.reset_target or ""
  local dir = bog.userdir .. "/lua"
  if target == "" then
    -- sys.rmtree, not a `rm -rf` shell-out: there is no rm on native Windows,
    -- and interpolating a path into a shell command was never a good idea even
    -- where there is. The C side also refuses "/", "", "." and "..", and uses
    -- lstat so a symlink in the overlay dir is unlinked rather than followed.
    local ok, err = sys.rmtree(dir)
    if ok then io.write("removed overlay dir ", dir, "\n")
    else io.write("could not remove ", dir, ": ", tostring(err), "\n") end
  else
    local p = dir .. "/" .. target .. ".lua"
    os.remove(p)
    io.write("removed ", p, "\n")
  end
  return 0
end

-- ---- REPL ------------------------------------------------------------------
local function print_help()
  io.write([[
boggart commands:
  /help            this help
  /tools [name]    list tools with scope + usage; name shows its source
  /memory          list stored memories
  /sessions        list recent saved sessions
  /resume <id>     resume a saved session
  /reload          hot-reload the harness Lua
  /reset [file]    delete an overlay file (or all with no arg), then reload
  /model <id>      switch model (current: ]] .. bog.session.model .. [[)
  /new             start a fresh conversation (new saved session)
  /quit            exit
Anything else is sent to the agent.
]])
end

local function handle_command(line)
  local cmd, rest = line:match("^/(%S+)%s*(.*)$")
  if cmd == "help" then print_help()
  elseif cmd == "quit" or cmd == "exit" then return true
  elseif cmd == "tools" then
    io.write(bog.tools.report(rest ~= "" and { name = rest } or {}), "\n")
  elseif cmd == "memory" then
    io.write(bog.memory.index_text(), "\n")
  elseif cmd == "sessions" then
    for _, s in ipairs(bog.store.sess_list(20)) do
      io.write(string.format("  %d  %s  %s\n", s.id,
        os.date("%Y-%m-%d %H:%M", s.updated), s.title or "(untitled)"))
    end
  elseif cmd == "resume" then
    local id = tonumber(rest)
    if id and bog.resume_session(id) then
      io.write("resumed session ", id, " (", tostring(#bog.session.messages), " messages)\n")
    else
      io.write("no such session: ", tostring(rest), "\n")
    end
  elseif cmd == "reload" then
    local ok, err = bog.reload()
    io.write(ok and "reloaded.\n" or ("reload failed:\n" .. err .. "\n"))
  elseif cmd == "reset" then
    boggart.reset_target = rest ~= "" and rest or ""
    do_reset()
    bog.reload()
  elseif cmd == "model" then
    if rest ~= "" then bog.session.model = rest end
    io.write("model = ", bog.session.model, "\n")
  elseif cmd == "new" then
    bog.new_session()
    io.write("started new session ", tostring(bog.session.id), ".\n")
  else
    io.write("unknown command: /", tostring(cmd), " (try /help)\n")
  end
  return false
end

local function run_one_turn(text)
  local S = bog.session
  if not S.title or S.title == "" then S.title = text:gsub("%s+", " "):sub(1, 60) end
  local ok, err = bog.try(function()
    bog.api.run_turn(text, function(t) io.write(t); io.flush() end)
  end)
  io.write("\n")
  if not ok then io.write(COL.err, "error: ", err, COL.reset, "\n") end
  bog.save_session() -- persist transcript for /resume and crash recovery
end

local function do_repl()
  io.write("boggart ", bog.version, "  model=", bog.session.model,
    "  (/help for commands)\n")
  -- Persist REPL history across sessions. isocline handles the file; linenoise
  -- never had this wired up.
  if sys.history_file then sys.history_file(bog.userdir .. "/history", 500) end
  while true do
    local line = sys.readline("boggart")
    if line == nil then io.write("\n"); break end
    if line ~= "" then sys.add_history(line) end
    if line:sub(1, 1) == "/" then
      if handle_command(line) then break end
    elseif line:match("%S") then
      run_one_turn(line)
    end
  end
  return 0
end

-- ---- dispatch --------------------------------------------------------------
if bog.mode == "init" then return do_init() end
if bog.mode == "reset" then return do_reset() end

-- everything below needs the harness wired
local ok, err = bog.try(wire)
if not ok then
  io.stderr:write("boggart: failed to load harness:\n", err, "\n")
  return 1
end

-- Open the local SQLite store (memory, sessions, kv, metadata).
local sok, serr = bog.try(bog.store.open)
if not sok then
  io.stderr:write("boggart: failed to open local store:\n", serr, "\n")
  return 1
end

-- Expose json and the gold stdlib as real globals so define_tool bodies can use
-- them (the system prompt tells the model they may) without tripping strict.
global{ json = bog.json, gold = require("gold") }

strict.enable() -- lock globals now that libs + bog are in place

-- Connect any declared MCP servers (~/.boggart/lua/mcp_servers.lua). Skipped in
-- eval mode so tests don't spawn subprocesses.
if bog.mode ~= "eval" then bog.try(bog.mcphost.load) end

if bog.mode == "swarm" then
  -- Load the actor layer lazily (swarm-only; keeps the default wiring minimal).
  bog.sched = require("sched")
  bog.skills = require("skills")
  bog.agents = require("agents")
  bog.thread = require("thread")
  bog.tools_swarm = require("tools_swarm")
  return require("swarmmode").run() -- "swarm" is the C bus global; the mode lives in swarmmode.lua

elseif bog.mode == "eval" then
  local chunk = assert(loadfile(boggart.eval_file))
  local rc = chunk()
  return type(rc) == "number" and rc or 0

elseif bog.mode == "headless" then
  bog.new_session()
  local input = io.read("*a") or ""
  input = input:gsub("%s+$", "")
  if input ~= "" then run_one_turn(input) end
  return 0

elseif bog.mode == "oneshot" then
  bog.new_session()
  run_one_turn(boggart.prompt or "")
  return 0

else
  bog.new_session()
  return do_repl()
end
