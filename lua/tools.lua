-- tools.lua -- the tool registry: pi-minimal defaults (read/write/edit/bash/
-- list) plus the meta-tools ds4 deliberately lacks (define_tool, reload). User-
-- and model-defined tools are plain .lua files under ~/.boggart/lua/tools/,
-- loaded fresh every time this module initializes (so reload re-scans them).
local util = require("util")
local json = require("json")
local events = require("events")

local M = {}
M.registry = {}

function M.register(name, def)
  M.registry[name] = def
end

-- ---- default tools ---------------------------------------------------------

local function tool_read(a)
  local path = a.path
  if type(path) ~= "string" then return M.err(M.ERR.validation, "read requires 'path'") end
  local data, err = util.read_file(path)
  if not data then return M.err(M.ERR.capability, "cannot read " .. path .. ": " .. tostring(err)) end
  if #data > 16 * 1024 * 1024 then return M.err(M.ERR.too_large, "file too large (>16MiB)") end

  -- split into lines
  local lines = {}
  for line in (data .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  -- gmatch above yields a trailing empty element for the final newline; drop it
  if lines[#lines] == "" then lines[#lines] = nil end
  local total = #lines

  if a.whole then
    return string.format("%s (%d lines)\n%s", path, total, data)
  end

  local start = math.max(1, math.floor(tonumber(a.start_line) or 1))
  local maxl = math.max(1, math.floor(tonumber(a.max_lines) or 120))
  local last = math.min(total, start + maxl - 1)
  local out = {}
  for i = start, last do out[#out + 1] = string.format("%d\t%s", i, lines[i]) end
  local header = string.format("%s lines %d-%d of %d", path, start, last, total)
  if last < total then
    header = header .. string.format(" (continue_offset=%d)", last + 1)
  end
  return header .. "\n" .. table.concat(out, "\n")
end

local function tool_write(a)
  if type(a.path) ~= "string" then return M.err(M.ERR.validation, "write requires 'path'") end
  if type(a.content) ~= "string" then return M.err(M.ERR.validation, "write requires string 'content'") end
  -- create parent dir
  local parent = a.path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then sys.mkdir_p(parent) end
  local ok, err = util.write_file(a.path, a.content)
  if not ok then return M.err(M.ERR.runtime, tostring(err)) end
  local n = select(2, a.content:gsub("\n", "\n")) + 1
  -- Only the write/edit tools announce themselves. A generated tool that
  -- reaches the filesystem another way (sys.exec "sed -i") is invisible here,
  -- and pretending otherwise would be worse than the gap: this is "the agent
  -- used its write tool", not "the disk changed".
  events.emit("file:write", { path = a.path, bytes = #a.content, lines = n })
  return string.format("Wrote %s (%d bytes, %d lines)", a.path, #a.content, n)
end

local function tool_edit(a)
  if type(a.path) ~= "string" then return M.err(M.ERR.validation, "edit requires 'path'") end
  if type(a.old) ~= "string" or a.old == "" then return M.err(M.ERR.validation, "edit requires a non-empty 'old'") end
  if type(a.new) ~= "string" then return M.err(M.ERR.validation, "edit requires 'new'") end
  local data, err = util.read_file(a.path)
  if not data then return M.err(M.ERR.capability, "cannot read " .. a.path .. ": " .. tostring(err)) end

  -- count occurrences (plain, non-pattern)
  local first = data:find(a.old, 1, true)
  if not first then return M.err(M.ERR.validation, "`old` not found in " .. a.path) end
  local second = data:find(a.old, first + 1, true)
  if second then return M.err(M.ERR.validation, "`old` matches more than once in " .. a.path .. "; add context to make it unique") end

  local before = data:sub(1, first - 1)
  local after = data:sub(first + #a.old)
  local updated = before .. a.new .. after
  local ok, werr = util.write_file(a.path, updated)
  if not ok then return M.err(M.ERR.runtime, tostring(werr)) end
  events.emit("file:edit", { path = a.path, bytes = #updated })

  -- return post-edit context (ds4 6.4): cheap tokens to save a re-read
  local start_line = select(2, before:gsub("\n", "\n")) + 1
  local new_line_count = select(2, a.new:gsub("\n", "\n")) + 1
  local ulines = {}
  for line in (updated .. "\n"):gmatch("(.-)\n") do ulines[#ulines + 1] = line end
  if ulines[#ulines] == "" then ulines[#ulines] = nil end
  local ctx_from = math.max(1, start_line - 4)
  local ctx_to = math.min(#ulines, start_line + new_line_count + 4)
  local ctx = {}
  for i = ctx_from, ctx_to do ctx[#ctx + 1] = string.format("%d\t%s", i, ulines[i]) end
  return string.format("Edited %s. Post-edit context (lines %d-%d of %d):\n%s",
    a.path, ctx_from, ctx_to, #ulines, table.concat(ctx, "\n"))
end

local function tool_bash(a)
  if type(a.command) ~= "string" then return M.err(M.ERR.validation, "bash requires 'command'") end
  local timeout = tonumber(a.timeout_sec) or 120
  -- proc.run, not sys.exec: under the swarm scheduler this yields between
  -- polls so a long build no longer freezes every other agent (and every
  -- in-flight LLM stream with it). Off a coroutine it blocks on the loop,
  -- which is the same observable behaviour as before.
  local r = require("proc").run(a.command, timeout)
  local out = r.out or ""
  local shaped = util.shape_result(out, { max_bytes = 6000, head_lines = 100 })
  local status = string.format("[exit=%d%s]", r.code, r.timed_out and " TIMED OUT" or "")
  if shaped == "" then return status .. " (no output)" end
  return status .. "\n" .. shaped
end

local function tool_list(a)
  local path = a.path or "."
  local names, err = sys.listdir(path)
  if not names then return M.err(M.ERR.capability, "cannot list " .. path .. ": " .. tostring(err)) end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local kind = sys.stat(path .. "/" .. name)
    out[#out + 1] = (kind == "dir") and (name .. "/") or name
  end
  return string.format("%s (%d entries)\n%s", path, #names, table.concat(out, "\n"))
end

-- ---- model-defined tools ---------------------------------------------------

-- ---------------------------------------------------------------------------
-- The capability surface for generated tools
--
-- boggart's sandbox is not a Lua sandbox: it is the C/Lua boundary. Capability
-- primitives live in C, where the policy lives with them -- sys.rmtree refuses
-- "/" and uses lstat so it cannot be walked out of the overlay directory,
-- proc.run bounds output and enforces a timeout, db goes through the store.
-- Lua's job is to *compose* those, not to reimplement them.
--
-- That boundary only means something if composition cannot step around it, and
-- until now it could: a tool body compiled with a bare load() inherited _G, so
-- io.open, os.remove and -- since libuv was vendored -- uv.spawn and
-- uv.fs_unlink all sat next to the guarded sys.* calls, with no policy on any
-- of them. Every guard in C was one `require("uv")` away from irrelevant.
--
-- So a generated body gets this table as its _ENV instead of _G. Note what is
-- deliberately absent: io, the destructive half of os, package/require/load,
-- debug, and raw uv/http/swarm/mcp. Those are harness infrastructure, not
-- vocabulary for a tool.
--
-- This is emphatically NOT a security boundary against the agent itself -- the
-- agent can edit lua/tools.lua and reload, which is the entire point of the
-- project. It is a capability boundary, and it earns its keep three ways:
-- accidental damage stays contained; bounds, limits and tracing can be enforced
-- once in C because there is no second route; and the model can see exactly
-- what it has to compose with. It also becomes a real security boundary the day
-- project-scoped tools are loaded out of a repository someone else wrote.
-- getenv is genuinely useful (HOME, PATH, EDITOR) but it is also a one-line
-- route to a credential, and "read the key and call the API directly" is a
-- plausible thing for a model to write while composing a tool. Names that look
-- like secrets are refused.
--
-- Not airtight, and not pretended to be: a tool can still call sys.exec("env").
-- The distinction being drawn is between a casual one-liner and a deliberate
-- shell-out -- the same distinction the whole capability boundary draws.
local SECRETISH = { "KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH" }
local function safe_getenv(name)
  if type(name) ~= "string" then return nil end
  local up = name:upper()
  for _, pat in ipairs(SECRETISH) do
    if up:find(pat, 1, true) then return nil end
  end
  return os.getenv(name)
end

local SAFE_OS = { time = os.time, date = os.date, clock = os.clock,
                  getenv = safe_getenv, difftime = os.difftime }

local function tool_env()
  local env = {
    -- capabilities (C-backed, policy included)
    sys = sys, db = db, json = json, gold = gold,
    -- composition: call any other registered tool, built-in or generated (§7)
    tools = { call = function(n, a) return M.run(n, a) end,
              names = function() return M.names() end },
    -- Telling a human something, and announcing your own events. `on` is
    -- deliberately absent: registration goes through the on_event tool so that
    -- every handler is listed in one place with a description attached.
    events = { notify = events.notify, emit = events.emit, list = events.list },
    -- pure Lua stdlib
    string = string, table = table, math = math, utf8 = utf8, os = SAFE_OS,
    ipairs = ipairs, pairs = pairs, next = next, select = select,
    tonumber = tonumber, tostring = tostring, type = type,
    pcall = pcall, xpcall = xpcall, error = error, assert = assert,
    rawget = rawget, rawset = rawset, rawequal = rawequal, rawlen = rawlen,
    setmetatable = setmetatable, getmetatable = getmetatable,
    coroutine = coroutine, -- proc.run yields through this under the scheduler
  }
  env._G = env
  return env
end
M.tool_env = tool_env

-- Build a tool def from parts. The body is a Lua chunk that receives `args`
-- and must `return` a string.
local function build_def(name, description, input_schema, body)
  -- "t" = text chunks only (no precompiled bytecode, which bypasses the
  -- verifier), and an explicit _ENV so the body cannot reach _G.
  local chunk, err = load("return function(args)\n" .. body .. "\nend",
                          "@tool:" .. name, "t", tool_env())
  if not chunk then error("tool body compile error: " .. err) end
  local runner = chunk()
  return {
    description = description,
    input_schema = input_schema or { type = "object", properties = {} },
    body = body, -- kept so we can re-serialize
    run = runner,
  }
end

-- ---------------------------------------------------------------------------
-- Scopes (paper §9)
--
--   session  in memory only; dies with the process. For task-shaped helpers
--            ("compare these three configs") that have no life beyond today.
--   project  keyed to the current repository. This is where learned repository
--            expertise belongs, and the reason a later session can start with
--            better operational knowledge than the first one had.
--   global   every project, forever. Powerful and easy to regret.
--
-- Default is `project`, which is the case the whole idea exists for. Global is
-- available but never the default: a tool that silently applies everywhere is
-- how an agent accumulates surprising behaviour it cannot explain later.
--
-- Project tools are stored under ~/.boggart/projects/<slug>/, NOT inside the
-- repository. That is deliberate. Committing generated tools would mean a
-- checkout could inject executable code into anyone's agent, which is the
-- untrusted-repository problem in §16.7. Keeping them in the user's own
-- directory means a tool is only ever code this user's agent wrote.
-- Bracketed: `global` is a reserved word in Lua 5.5, so it cannot appear as a
-- bare key in a table constructor. The scope is still named "global" to users.
M.SCOPES = { session = true, project = true, ["global"] = true }

-- Identify the project: the git root if there is one, else the working
-- directory. The git root is the better key because it is stable no matter
-- which subdirectory the agent happens to be started from.
local project_cache = nil
-- Drop the cached project root. Needed when the working directory changes
-- while the process is running -- which it now can, because the GUI lets you
-- choose a folder to work in. Without this, project-scoped tools would keep
-- being filed under the directory boggart happened to start in.
function M.forget_project() project_cache = nil end

-- The project root only if it is already known.
--
-- project_root() shells out to `git rev-parse`, and proc.run yields
-- ("proc", handle) when it is called from inside a coroutine -- correct under
-- boggart's scheduler, and fatal anywhere else, because the editor's thread
-- runner expects a yield to be a number of seconds. Callers that merely want
-- to *report* the root must not be the ones to compute it.
function M.project_root_cached() return project_cache end

function M.project_root()
  if project_cache then return project_cache end
  local r = require("proc").run("git rev-parse --show-toplevel", 10)
  local root = (r.code == 0) and (r.out or ""):match("^%s*(.-)%s*$") or nil
  if not root or root == "" or root:find("\n") then root = sys.cwd() end
  project_cache = root
  return root
end

-- A filesystem-safe, human-recognisable directory name for a project path.
-- The basename keeps it readable; the digest keeps two same-named checkouts
-- apart. Lua has no crypto here, and none is needed -- this is a bucket name,
-- not a security boundary.
local function project_slug(root)
  local base = root:gsub("[/\\]+$", ""):match("([^/\\]+)$") or "root"
  local h = 5381
  for i = 1, #root do h = (h * 33 + root:byte(i)) % 0x7FFFFFFF end
  return (base:gsub("[^%w%-_]", "_")) .. "-" .. string.format("%08x", h)
end

local function tools_dir(scope)
  if scope == "project" then
    return bog.userdir .. "/projects/" .. project_slug(M.project_root()) .. "/tools"
  end
  return bog.userdir .. "/lua/tools" -- global (and the pre-scope location)
end
M.tools_dir = tools_dir

local function git_rev()
  local r = require("proc").run("git rev-parse --short HEAD", 10)
  if r.code ~= 0 then return nil end
  local rev = (r.out or ""):match("^%s*(%w+)%s*$")
  return rev
end

-- Current HEAD, cached per process: this is consulted whenever a project tool
-- fails, and shelling out to git on every failure would be silly.
local rev_cache, rev_done = nil, false
function M.current_rev()
  if not rev_done then rev_done = true; rev_cache = git_rev() end
  return rev_cache
end

-- Was this tool learned against a different revision of the repository?
--
-- This is what makes procedural memory *verifiable* rather than stale prose
-- (paper §18). A tool that encodes "command metadata lives in this file, in
-- this shape" can quietly stop being true, and the repository moving is the
-- cheapest available signal that it might have. It is a hint, not a verdict --
-- most commits do not invalidate most tools -- so it is only surfaced where it
-- is actually useful: next to a failure, and in the report.
function M.stale_note(name, d)
  if not d or d.scope ~= "project" then return nil end
  if not bog.db or not bog.store or not bog.store.tool_stats then return nil end
  local cur = M.current_rev()
  if not cur then return nil end
  local okq, rows = pcall(bog.store.tool_stats, d.project or "")
  if not okq then return nil end
  for _, r in ipairs(rows) do
    if r.name == name and r.scope == "project" and r.git_rev and r.git_rev ~= cur then
      return string.format("this tool was written against %s and HEAD is now %s; "
        .. "the code it assumes may have moved", r.git_rev, cur)
    end
  end
  return nil
end

-- Render a standalone .lua file that reconstructs a tool def when loaded.
-- A persisted tool file is pure *data*: description, schema, and the body as a
-- string. It deliberately does not compile anything itself.
--
-- The previous format embedded a bare load() in the generated file, so a tool
-- restored after a restart got the full _G back and the capability boundary
-- lasted exactly one session. Emitting data instead means there is a single
-- compilation path -- build_def -- and therefore a single place the sandbox
-- environment is applied.
local function render_tool_file(name, description, input_schema, body)
  return table.concat({
    "-- boggart tool: " .. name .. " (generated by define_tool; safe to edit)",
    "-- Data only: `body` is compiled by lua/tools.lua against the capability",
    "-- environment. Adding code here will not run -- it is loaded with an empty",
    "-- environment precisely so the file cannot do anything on its own.",
    "return {",
    "  description = " .. string.format("%q", description) .. ",",
    "  input_schema = " .. util.serialize(input_schema) .. ",",
    "  body = " .. string.format("%q", body) .. ",",
    "}",
    "",
  }, "\n")
end

local function load_scope(scope)
  local dir = tools_dir(scope)
  if sys.stat(dir) ~= "dir" then return end
  local project = (scope == "project") and M.project_root() or ""
  for _, fname in ipairs(sys.listdir(dir) or {}) do
    if fname:match("%.lua$") then
      local name = fname:gsub("%.lua$", "")
      local ok, def = pcall(function()
        -- Text mode and an EMPTY environment: the file is data, so it needs no
        -- globals at all, and a tool file that has grown code cannot run it.
        local chunk = assert(loadfile(dir .. "/" .. fname, "t", {}))
        return chunk()
      end)
      -- Compile through build_def so the body picks up the capability
      -- environment. This is the only route from a stored body to a callable
      -- tool, which is what makes the boundary survive a restart.
      if ok and type(def) == "table" and type(def.body) == "string" then
        local bok, built = pcall(build_def, name, def.description or name,
                                 def.input_schema, def.body)
        if bok then
          built.scope, built.project = scope, project
          M.registry[name] = built
        else bog.log("skipping tool " .. name .. ": " .. tostring(built)) end
      elseif ok and type(def) == "table" and type(def.run) == "function" then
        -- Pre-sandbox file format: it carries a compiled closure built against
        -- _G. Refuse it rather than register something that quietly has more
        -- authority than every tool around it; re-defining the tool rewrites
        -- the file in the current format.
        bog.log("ignoring legacy unsandboxed tool file " .. fname
          .. " (re-run define_tool for '" .. name .. "' to migrate it)")
      else
        bog.log("skipping bad tool file " .. fname .. ": " .. tostring(def))
      end
    end
  end
end

-- Global first, then project, so a project tool deliberately shadows a global
-- one of the same name: the more specific knowledge about *this* repository
-- should win over a general helper. Session tools are never on disk.
local function load_user_tools()
  load_scope("global")
  load_scope("project")
end

local function tool_define(a)
  local name = a.name
  if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
    return M.err(M.ERR.validation, "define_tool needs a 'name' matching [A-Za-z_][A-Za-z0-9_]*")
  end
  if type(a.description) ~= "string" or a.description == "" then
    return M.err(M.ERR.validation, "define_tool needs a 'description'")
  end
  if type(a.lua) ~= "string" or a.lua == "" then
    return M.err(M.ERR.validation, "define_tool needs a Lua 'lua' body that returns a string")
  end
  local schema = a.input_schema
  if schema == nil or schema == json.null then schema = { type = "object", properties = {} } end
  if type(schema) ~= "table" then return M.err(M.ERR.validation, "'input_schema' must be a JSON object") end
  -- An empty `required` decodes to an empty Lua table, which json.encode would
  -- emit as {} (an object) -- invalid JSON Schema. Drop it if empty.
  if type(schema.required) == "table" and next(schema.required) == nil then schema.required = nil end

  local ok, def = pcall(build_def, name, a.description, schema, a.lua)
  -- A body that will not compile is bad *input* to define_tool, not a fault in
  -- a tool -- the model should fix the code it just submitted. Strip our own
  -- frame off the front so the message points at the body's line, not at
  -- tools.lua's.
  if not ok then
    return M.err(M.ERR.validation, (tostring(def):gsub("^.-tool body compile error: ", "")))
  end

  local scope = a.scope or "project"
  if not M.SCOPES[scope] then
    return M.err(M.ERR.validation, "scope must be session, project or global (got %q)", tostring(scope))
  end
  def.scope = scope
  def.project = (scope == "project") and M.project_root() or ""

  if scope == "session" then
    -- Nothing on disk: it exists for this process and no longer.
    M.registry[name] = def
    M.record_provenance(name, def)
    return string.format("Defined tool '%s' (scope=session; it will not persist).", name)
  end

  local dir = tools_dir(scope)
  sys.mkdir_p(dir)
  local fileok, ferr = util.write_file(dir .. "/" .. name .. ".lua",
    render_tool_file(name, a.description, schema, a.lua))
  if not fileok then return M.err(M.ERR.capability, "could not save tool: " .. tostring(ferr)) end

  M.registry[name] = def
  M.record_provenance(name, def)
  return string.format("Defined tool '%s' (scope=%s%s). Available now; persisted to %s/%s.lua",
    name, scope,
    scope == "project" and (", project=" .. def.project) or "",
    dir, name)
end

local function tool_reload(a)
  local ok, err = bog.reload()
  if not ok then return M.err(M.ERR.runtime, "reload failed (old code kept): " .. tostring(err)) end
  return "Reloaded harness. Active tools: " .. table.concat(M.names(), ", ")
end

-- ---- registry assembly -----------------------------------------------------

function M.names()
  local ns = {}
  for name in pairs(M.registry) do ns[#ns + 1] = name end
  table.sort(ns)
  return ns
end

-- The tool list sent to the API each turn.
function M.schemas()
  local out = {}
  for _, name in ipairs(M.names()) do
    local d = M.registry[name]
    out[#out + 1] = {
      name = name,
      description = d.description or "",
      input_schema = d.input_schema or { type = "object", properties = {} },
    }
  end
  return out
end

-- Is `name` permitted by an allow set? Entries are exact names or trailing-`*`
-- wildcards, e.g. "mcp__github__*" grants every tool from that MCP server. This
-- is boggart's per-agent tool management: many tools can exist, but each agent
-- only sees the slice its skills grant.
function M.allowed(allow, name)
  if allow[name] then return true end
  for pat in pairs(allow) do
    if pat:sub(-1) == "*" then
      local pre = pat:sub(1, #pat - 1)
      if name:sub(1, #pre) == pre then return true end
    end
  end
  return false
end

-- Like schemas(), but restricted to the names permitted by the allow set
-- (per-agent tool surface in swarm mode; supports wildcard entries).
function M.schemas_for(allow)
  local out = {}
  for _, name in ipairs(M.names()) do
    if M.allowed(allow, name) then
      local d = M.registry[name]
      out[#out + 1] = {
        name = name,
        description = d.description or "",
        input_schema = d.input_schema or { type = "object", properties = {} },
      }
    end
  end
  return out
end

-- Run a tool by name; may return a "Tool error: ..." string or raise (the API
-- loop turns a raise into a tool_result too).
-- ---------------------------------------------------------------------------
-- Execution limits for generated tools
--
-- A generated tool is model-written code, and the failure mode that matters is
-- the boring one: an accidental infinite loop. Since everything now shares one
-- libuv loop, a spinning tool does not just hang its own agent -- it stops the
-- scheduler reaching http.pump and every other agent's token stream stalls
-- behind it. Bounding it is what makes the shared loop safe.
--
-- The budget is on *instructions*, not wall clock, and that distinction is the
-- whole design. A tool that shells out to a ten-minute build is legitimate and
-- spends that time yielded, executing nothing; a tool stuck in `while true do
-- end` burns instructions. Wall-clock limits would kill the first and are not
-- needed for the second -- proc.run already carries its own timeout for I/O.
--
-- Enforced with a count hook. `debug` is deliberately absent from the tool
-- environment, so a body cannot clear the hook that is watching it.
M.LIMITS = {
  instructions = 200e6,     -- ~a few seconds of a tight loop
  memory_kb    = 256 * 1024,-- growth, not total: the session is already large
  check_every  = 200000,    -- hook granularity
  result_bytes = 1024 * 1024,
}

-- Real allocated bytes, in KB.
--
-- sys.membytes() (src/lmem.c) counts every allocation Lua makes, because
-- collectgarbage("count") cannot be trusted for this: Lua 5.5 stopped
-- accounting for string memory there. Measured on the upgrade, 2,000 retained
-- 100 KB strings reported a 62 KB delta while 200,000 small tables reported a
-- correct 14 MB -- so the limit had gone blind to exactly the likeliest way a
-- generated tool blows memory, which is building an enormous string.
--
-- Falls back to the GC's view if the counting allocator is not installed, so
-- an embedder that creates its own lua_State still gets *some* limit.
local function used_kb()
  if sys.membytes then return (select(1, sys.membytes())) / 1024 end
  return collectgarbage("count")
end

-- Error taxonomy. The "Tool error:" prefix is load-bearing -- api.lua tests the
-- first 11 characters to set is_error on the tool_result -- so the kind goes
-- after it. The point (paper §15) is that the model can tell *what to do*:
-- fix the tool, change the invocation, or fall back to primitives. A single
-- opaque error class leaves it guessing.
M.ERR = {
  validation = "validation_error",     -- bad arguments: change the invocation
  permission = "permission_error",     -- not allowed: ask, or use another route
  not_found  = "tool_not_found",       -- no such tool: check the name
  runtime    = "runtime_error",        -- the body raised: fix the tool
  timeout    = "timeout",              -- instruction budget gone: it is looping
  resource   = "resource_limit",       -- memory: the tool needs a smaller working set
  cancelled  = "cancelled",
  too_large  = "result_too_large",     -- narrow the query, or read the file
  capability = "host_capability_error",-- a host call failed: usually not the tool
}

function M.err(kind, fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  return string.format("Tool error: [%s] %s", kind, msg)
end

local LIMIT_SENTINEL = "\0__bog_limit__"

-- Run a generated body under the instruction/memory budget.
local function run_bounded(d, args)
  local ticks, tripped, tripped_kind = 0, nil, M.ERR.timeout
  local mem0 = used_kb()
  local step = M.LIMITS.check_every

  debug.sethook(function()
    ticks = ticks + step
    if ticks > M.LIMITS.instructions then
      tripped = string.format("exceeded the instruction budget (%d)", M.LIMITS.instructions)
      error(LIMIT_SENTINEL, 0)
    end
    if used_kb() - mem0 > M.LIMITS.memory_kb then
      tripped_kind = M.ERR.resource
      tripped = string.format("allocated more than %d MB", M.LIMITS.memory_kb // 1024)
      error(LIMIT_SENTINEL, 0)
    end
  end, "", step)

  -- pcall is yieldable in 5.4, so a body that yields through proc.run still
  -- reaches the scheduler; the hook is per-coroutine and survives the yield.
  local ok, res = pcall(d.run, args)
  debug.sethook()

  if not ok then
    if tripped then return M.err(tripped_kind, "%s and was stopped", tripped) end
    return M.err(M.ERR.runtime, tostring(res))
  end
  return res
end

-- Record who made a tool, when, and against which revision (paper §17).
-- Best-effort: a store that is not open must never stop a tool working.
function M.record_provenance(name, def)
  if not bog.db or not bog.store or not bog.store.tool_record then return end
  pcall(bog.store.tool_record, name, def.scope or "global", def.project or "", {
    session_id = bog.session and bog.session.id,
    version = bog.version,
    git_rev = (def.scope == "project") and git_rev() or nil,
  })
end

function M.run(name, input)
  local d = M.registry[name]
  if not d then
    -- No tool:before for a tool that does not exist: nothing is about to run,
    -- and a handler that saw a "before" with no "after" would be right to
    -- complain. Past this line the pair is guaranteed.
    return M.err(M.ERR.not_found, "unknown tool: %s", tostring(name))
  end
  events.emit("tool:before", { name = name, input = input })

  -- Built-ins are harness code and trusted; skipping the hook keeps read/edit
  -- on their fast path. Only model-authored bodies carry a `body` string.
  local res
  if d.body then
    local t0 = os.clock()
    res = run_bounded(d, input or {})
    -- Usage accounting (paper §24): calls, failures and cumulative time are
    -- what turn "did this tool pay for itself" from a rhetorical question into
    -- an answerable one.
    local failed = type(res) == "string" and res:sub(1, 11) == "Tool error:"
    if bog.db and bog.store and bog.store.tool_used then
      pcall(bog.store.tool_used, name, d.scope or "global", d.project or "",
            (os.clock() - t0) * 1000, failed)
    end
    -- A failure is the moment the staleness hint is worth spending tokens on:
    -- it tells the model to suspect the *procedure* rather than only its own
    -- invocation, which is the difference between fixing the tool and giving up
    -- on the abstraction.
    if failed then
      local okn, note = pcall(M.stale_note, name, d)
      if okn and note then res = res .. "\n(note: " .. note .. ")" end
    end
  else
    local ok, r = pcall(d.run, input or {})
    if not ok then return M.err(M.ERR.runtime, tostring(r)) end
    res = r
  end

  -- A tool returning 50,000 lines has defeated the purpose (paper §14): spill
  -- to a file and hand back a head plus the path, exactly as bash and read do.
  if type(res) ~= "string" then res = tostring(res) end
  if #res > M.LIMITS.result_bytes then
    local shaped = util.shape_result(res, { max_bytes = 6000, head_lines = 100 })
    res = M.err(M.ERR.too_large,
      "%d bytes exceeds the %d byte cap. Head follows; read the saved file for the rest.\n%s",
      #res, M.LIMITS.result_bytes, shaped)
  end
  -- The size of the result, never the result: a tool that legitimately returns
  -- a megabyte would otherwise put it on the bus for every subscriber.
  if events.any("tool:after") then
    events.emit("tool:after", { name = name, bytes = #res,
                                error = res:sub(1, 11) == "Tool error:" })
  end
  return res
end

-- Populate the registry (called fresh on every load/reload).
M.registry = {}
M.register("read", {
  description = "Read a file in bounded line chunks. Reports continue_offset for the next chunk.",
  input_schema = {
    type = "object",
    properties = {
      path = { type = "string" },
      start_line = { type = "integer", description = "1-based first line (default 1)" },
      max_lines = { type = "integer", description = "max lines to return (default 120)" },
      whole = { type = "boolean", description = "read the entire file" },
    },
    required = { "path" },
  },
  run = tool_read,
})
M.register("write", {
  description = "Write (create/overwrite) a file with the given content. Creates parent dirs.",
  input_schema = {
    type = "object",
    properties = { path = { type = "string" }, content = { type = "string" } },
    required = { "path", "content" },
  },
  run = tool_write,
})
M.register("edit", {
  description = "Replace the single exact occurrence of `old` with `new` in a file. Fails if `old` "
    .. "is absent or occurs more than once. Returns post-edit context.",
  input_schema = {
    type = "object",
    properties = { path = { type = "string" }, old = { type = "string" }, new = { type = "string" } },
    required = { "path", "old", "new" },
  },
  run = tool_edit,
})
M.register("bash", {
  description = "Run a shell command via /bin/sh and return its combined stdout+stderr and exit code. "
    .. "Large output is saved to a temp file and summarized.",
  input_schema = {
    type = "object",
    properties = {
      command = { type = "string" },
      timeout_sec = { type = "integer", description = "wall-clock timeout (default 120)" },
    },
    required = { "command" },
  },
  run = tool_bash,
})
M.register("list", {
  description = "List a directory (directories are suffixed with /).",
  input_schema = {
    type = "object",
    properties = { path = { type = "string", description = "directory (default '.')" } },
  },
  run = tool_list,
})
-- Inspecting what has been learned, and whether it was worth it (paper §17/§24).
local function tool_tools(a)
  local stats = {}
  if bog.db and bog.store and bog.store.tool_stats then
    local okq, rows = pcall(bog.store.tool_stats, M.project_root())
    if okq then for _, r in ipairs(rows) do stats[r.name] = r end end
  end
  local names = M.names()
  local out = { string.format("%d tools active", #names) }
  local learned = {}
  for _, n in ipairs(names) do
    local d = M.registry[n]
    if d.body then learned[#learned + 1] = n end
  end
  if #learned == 0 then
    out[#out + 1] = "no model-defined tools yet"
  else
    out[#out + 1] = ""
    local cur = M.current_rev()
    out[#out + 1] = string.format("%-22s %-8s %6s %6s %9s %-5s  %s",
      "name", "scope", "calls", "fails", "avg ms", "rev", "description")
    for _, n in ipairs(learned) do
      local d, st = M.registry[n], stats[n] or {}
      local calls = st.calls or 0
      -- "stale" only means the repository has moved since the tool was
      -- written, which is a prompt to re-check it, not proof it is wrong.
      local rev = "-"
      if d.scope == "project" and st.git_rev then
        rev = (cur and st.git_rev ~= cur) and "stale" or "ok"
      end
      out[#out + 1] = string.format("%-22s %-8s %6d %6d %9s %-5s  %s",
        n, d.scope or "?", calls, st.failures or 0,
        calls > 0 and string.format("%.1f", (st.total_ms or 0) / calls) or "-",
        rev, (d.description or ""):sub(1, 60))
    end
  end
  if a and a.name and M.registry[a.name] and M.registry[a.name].body then
    out[#out + 1] = ""
    out[#out + 1] = "-- " .. a.name .. " --"
    out[#out + 1] = M.registry[a.name].body
  end
  return table.concat(out, "\n")
end
M.report = tool_tools

M.register("tools", {
  description = "List the tools you have defined, with scope and usage counts, so you can tell "
    .. "which ones are earning their keep. Pass a name to also see its source.",
  input_schema = { type = "object",
    properties = { name = { type = "string", description = "show this tool's body" } } },
  run = tool_tools,
})

M.register("define_tool", {
  description = "Create a new tool at runtime by writing its Lua. The body receives a table `args` "
    .. "and must `return` a string. It runs against a capability environment: sys (exec/listdir/stat/"
    .. "mkdir_p/rmtree/home/shell), db, json, gold, tools.call(name, args) to invoke another tool, "
    .. "events.notify(msg, level) to say something a human should see, "
    .. "and the pure Lua stdlib. Raw io/os/require/uv are deliberately absent -- compose the "
    .. "capabilities instead. This is how you grow your own vocabulary for a codebase.",
  input_schema = {
    type = "object",
    properties = {
      name = { type = "string", description = "tool name, [A-Za-z_][A-Za-z0-9_]*" },
      description = { type = "string" },
      input_schema = { type = "object", description = "JSON Schema for the tool's arguments" },
      lua = { type = "string", description = "Lua body; receives `args`, must return a string" },
      scope = { type = "string", enum = { "session", "project", "global" },
        description = "session = this process only; project (default) = this repository, "
          .. "available to future sessions here; global = every project, use sparingly" },
    },
    required = { "name", "description", "lua" },
  },
  run = tool_define,
})
-- ---------------------------------------------------------------------------
-- on_event: define_tool's mirror image -- code the harness calls, rather than
-- code the model calls.
--
-- Handlers registered this way are SESSION-ONLY, and that is a decision rather
-- than an omission. Persisting them would be easy: the same data-only file
-- format define_tool now uses (pattern + body string, compiled through one
-- path) would work unchanged, and would avoid repeating the mistake where a
-- persisted "tool" carried its own load() and got _G back after a restart.
--
-- The reason not to is *when the code runs*, not how it is stored. A persisted
-- tool sits inert until a model decides to call it, in a conversation someone
-- is watching, behind whatever approval gate the front end imposes on
-- run_tool. A persisted handler runs on the next start, on every matching
-- event, with nobody having asked for anything and no gate to put in its way --
-- and an event is not a call, so there is nothing for the studio to prompt
-- about. A bad tool costs one call; a bad handler on turn:start costs every
-- future session in this project, including the ones you start to fix it.
--
-- Durable reactions therefore go through a file the user can see:
-- ~/.boggart/lua/events/<name>.lua, which the agent may write with the `write`
-- tool and which takes effect on the next reload. That keeps a review point in
-- the loop without taking the capability away.
local function tool_on_event(a)
  local op = a.op or "on"

  if op == "list" then
    local rows = events.list()
    if #rows == 0 then return "no event handlers registered" end
    local out = { string.format("%-4s %-22s %-10s %6s %6s  %s",
      "id", "event", "source", "calls", "errs", "description") }
    for _, h in ipairs(rows) do
      out[#out + 1] = string.format("%-4d %-22s %-10s %6d %6d  %s",
        h.id, h.pattern, h.source or "?", h.calls, h.errors,
        (h.desc or "") .. (h.once and " (once)" or ""))
    end
    return table.concat(out, "\n")
  end

  if op == "off" then
    local id = tonumber(a.id)
    if not id then return M.err(M.ERR.validation, "on_event op=off needs the handler 'id'") end
    if not events.off(id) then return M.err(M.ERR.not_found, "no handler #%d", id) end
    return string.format("Removed handler #%d.", id)
  end

  if op ~= "on" then return M.err(M.ERR.validation, "op must be on, off or list") end
  if type(a.event) ~= "string" or a.event == "" then
    return M.err(M.ERR.validation, "on_event needs an 'event' pattern, e.g. \"tool:*\"")
  end
  if type(a.lua) ~= "string" or a.lua == "" then
    return M.err(M.ERR.validation, "on_event needs a Lua 'lua' body")
  end
  -- Same compilation rules as a tool body: text only, explicit _ENV, so a
  -- handler has exactly the capability surface a generated tool has.
  local chunk, err = load("return function(event, data)\n" .. a.lua .. "\nend",
                          "@handler:" .. a.event, "t", tool_env())
  if not chunk then
    return M.err(M.ERR.validation, (tostring(err):gsub("^%[string [^%]]*%]:", "line ")))
  end
  local h = events.on(a.event, chunk(), {
    once = a.once and true or nil,
    desc = a.desc or ("agent handler for " .. a.event),
    source = "agent",
  })
  return string.format(
    "Registered handler #%d for %q (session-only: it disappears when this "
    .. "process exits). It runs in its own coroutine, so throwing affects "
    .. "nothing else -- but it must not block or yield (no bash, no sys.exec) "
    .. "or it will be dropped. Write ~/.boggart/lua/events/<name>.lua to make a "
    .. "handler durable.", h.id, a.event)
end

M.register("on_event", {
  description = "React to something the harness does, instead of waiting to be called. Registers a "
    .. "Lua handler for an event pattern with `*` wildcards (\"tool:*\", \"file:write\", \"*\"); the "
    .. "body receives `event` (the name) and `data` (a small table) and runs in the same capability "
    .. "environment as define_tool, plus events.notify(msg, level) to tell the user something. "
    .. "Handlers are session-only; op=list shows them, op=off removes one. "
    .. "Events: " .. (function()
        local ns = {}
        for k in pairs(events.EVENTS) do ns[#ns + 1] = k end
        table.sort(ns)
        return table.concat(ns, ", ")
      end)(),
  input_schema = {
    type = "object",
    properties = {
      op = { type = "string", enum = { "on", "off", "list" },
             description = "default 'on'" },
      event = { type = "string", description = "event pattern, e.g. \"tool:*\"" },
      lua = { type = "string", description = "Lua body; receives `event`, `data`. Must not block." },
      desc = { type = "string", description = "what this handler is for (shown by op=list)" },
      once = { type = "boolean", description = "fire at most once, then unsubscribe" },
      id = { type = "integer", description = "handler id, for op=off" },
    },
  },
  run = tool_on_event,
})

M.register("reload", {
  description = "Hot-reload the harness Lua after you have edited files under ~/.boggart/lua/. "
    .. "On a syntax error the previous code is kept and the error is returned.",
  input_schema = { type = "object", properties = {} },
  run = tool_reload,
})

M.register("sql", {
  description = "Run SQL against boggart's local SQLite database (~/.boggart/boggart.db). "
    .. "By default runs a query and returns rows as JSON; set write=true for "
    .. "INSERT/UPDATE/DELETE/CREATE (returns changes+rowid). Use ? placeholders with params. "
    .. "Tables include memory, kv, sessions, meta -- and any you create. FTS5 is available.",
  input_schema = {
    type = "object",
    properties = {
      sql = { type = "string" },
      params = { type = "array", description = "positional values for ? placeholders" },
      write = { type = "boolean", description = "true for statements that modify data/schema" },
    },
    required = { "sql" },
  },
  run = function(a)
    if type(a.sql) ~= "string" then return M.err(M.ERR.validation, "sql requires 'sql'") end
    local params = a.params
    if params == json.null then params = nil end
    if a.write then
      local ok, r, e = pcall(bog.db.run, bog.db, a.sql, params)
      if not ok then return M.err(M.ERR.runtime, tostring(r)) end
      if r == nil then return M.err(M.ERR.runtime, tostring(e)) end
      return string.format("ok: changes=%d rowid=%d", r.changes, r.rowid)
    end
    local ok, rows, e = pcall(bog.db.query, bog.db, a.sql, params)
    if not ok then return M.err(M.ERR.runtime, tostring(rows)) end
    if rows == nil then return M.err(M.ERR.runtime, tostring(e)) end
    return string.format("%d row(s):\n%s", #rows, json.encode(rows))
  end,
})

M.register("kv", {
  description = "Get/set/delete/list simple key-value metadata in the local store.",
  input_schema = {
    type = "object",
    properties = {
      op = { type = "string", enum = { "get", "set", "del", "list" } },
      key = { type = "string" },
      value = { type = "string" },
    },
    required = { "op" },
  },
  run = function(a)
    local op = a.op
    if op == "get" then
      local v = bog.store.kv_get(a.key or "")
      return v ~= nil and v or "(nil)"
    elseif op == "set" then
      if type(a.key) ~= "string" then return M.err(M.ERR.validation, "kv set requires 'key'") end
      bog.store.kv_set(a.key, a.value or "")
      return "ok"
    elseif op == "del" then
      bog.store.kv_del(a.key or "")
      return "ok"
    elseif op == "list" then
      return json.encode(bog.store.kv_list(a.key))
    end
    return M.err(M.ERR.validation, "kv op must be get/set/del/list")
  end,
})

M.register("mcp_add", {
  description = "Connect an MCP server and register its tools as mcp__<name>__<tool>. "
    .. "stdio: {name, command, args?, env?}. http: {name, transport='http', url, headers?}.",
  input_schema = {
    type = "object",
    properties = {
      name = { type = "string" },
      transport = { type = "string", enum = { "stdio", "http" } },
      command = { type = "string" },
      args = { type = "array" },
      env = { type = "object" },
      url = { type = "string" },
      headers = { type = "array" },
    },
    required = { "name" },
  },
  run = function(a)
    if not bog.mcphost then return M.err(M.ERR.capability, "MCP host unavailable") end
    local names, err = bog.mcphost.add(a)
    if not names then return M.err(M.ERR.runtime, tostring(err)) end
    return string.format("connected '%s' with %d tool(s): %s", a.name, #names, table.concat(names, ", "))
  end,
})

M.register("mcp", {
  description = "List connected MCP servers and the tools they expose.",
  input_schema = { type = "object", properties = {} },
  run = function(a)
    if not bog.mcphost then return "(MCP host unavailable)" end
    local out = {}
    for _, s in ipairs(bog.mcphost.list()) do
      out[#out + 1] = s.server .. ": " .. table.concat(s.tools, ", ")
        .. "  [" .. bog.mcphost.generation(s.server) .. "]"
    end
    return #out > 0 and table.concat(out, "\n") or "(no MCP servers connected)"
  end,
})

-- memory tools
for name, def in pairs(bog.memory.tools) do M.register(name, def) end

-- plan/task tools: compiled procedures (run_plan/define_task/tasks). A defined
-- task chains tool calls with no model turn between them -- a skill minus the
-- per-step call. See lua/plan.lua.
for name, def in pairs(require("plan").tools) do M.register(name, def) end

-- goap tools: opt-in goal planning (goap/define_action/blackboard). The model
-- states a goal world-state; A* over declared actions finds the tool ordering.
-- See lua/goap.lua and lua/blackboard.lua.
for name, def in pairs(require("goap").tools) do M.register(name, def) end

-- claims tools: the shared edit blackboard (claim/release/claims) so concurrent
-- agents coordinate on files instead of colliding. See lua/claims.lua.
for name, def in pairs(require("claims").tools) do M.register(name, def) end

-- model/user-defined tool files
load_user_tools()

return M
