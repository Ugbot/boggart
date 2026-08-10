-- tools.lua -- the tool registry: pi-minimal defaults (read/write/edit/bash/
-- list) plus the meta-tools ds4 deliberately lacks (define_tool, reload). User-
-- and model-defined tools are plain .lua files under ~/.boggart/lua/tools/,
-- loaded fresh every time this module initializes (so reload re-scans them).
local util = require("util")
local json = require("json")

local M = {}
M.registry = {}

function M.register(name, def)
  M.registry[name] = def
end

-- ---- default tools ---------------------------------------------------------

local function tool_read(a)
  local path = a.path
  if type(path) ~= "string" then return "Tool error: read requires 'path'" end
  local data, err = util.read_file(path)
  if not data then return "Tool error: cannot read " .. path .. ": " .. tostring(err) end
  if #data > 16 * 1024 * 1024 then return "Tool error: file too large (>16MiB)" end

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
  if type(a.path) ~= "string" then return "Tool error: write requires 'path'" end
  if type(a.content) ~= "string" then return "Tool error: write requires string 'content'" end
  -- create parent dir
  local parent = a.path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then sys.mkdir_p(parent) end
  local ok, err = util.write_file(a.path, a.content)
  if not ok then return "Tool error: " .. tostring(err) end
  local n = select(2, a.content:gsub("\n", "\n")) + 1
  return string.format("Wrote %s (%d bytes, %d lines)", a.path, #a.content, n)
end

local function tool_edit(a)
  if type(a.path) ~= "string" then return "Tool error: edit requires 'path'" end
  if type(a.old) ~= "string" or a.old == "" then return "Tool error: edit requires a non-empty 'old'" end
  if type(a.new) ~= "string" then return "Tool error: edit requires 'new'" end
  local data, err = util.read_file(a.path)
  if not data then return "Tool error: cannot read " .. a.path .. ": " .. tostring(err) end

  -- count occurrences (plain, non-pattern)
  local first = data:find(a.old, 1, true)
  if not first then return "Tool error: `old` not found in " .. a.path end
  local second = data:find(a.old, first + 1, true)
  if second then return "Tool error: `old` matches more than once in " .. a.path .. "; add context to make it unique" end

  local before = data:sub(1, first - 1)
  local after = data:sub(first + #a.old)
  local updated = before .. a.new .. after
  local ok, werr = util.write_file(a.path, updated)
  if not ok then return "Tool error: " .. tostring(werr) end

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
  if type(a.command) ~= "string" then return "Tool error: bash requires 'command'" end
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
  if not names then return "Tool error: cannot list " .. path .. ": " .. tostring(err) end
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
local SAFE_OS = { time = os.time, date = os.date, clock = os.clock,
                  getenv = os.getenv, difftime = os.difftime }

local function tool_env()
  local env = {
    -- capabilities (C-backed, policy included)
    sys = sys, db = db, json = json, gold = gold,
    -- composition: call any other registered tool, built-in or generated (§7)
    tools = { call = function(n, a) return M.run(n, a) end,
              names = function() return M.names() end },
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

local function tools_dir()
  return bog.userdir .. "/lua/tools"
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

local function load_user_tools()
  local dir = tools_dir()
  if sys.stat(dir) ~= "dir" then return end
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
        if bok then M.registry[name] = built
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

local function tool_define(a)
  local name = a.name
  if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
    return "Tool error: define_tool needs a 'name' matching [A-Za-z_][A-Za-z0-9_]*"
  end
  if type(a.description) ~= "string" or a.description == "" then
    return "Tool error: define_tool needs a 'description'"
  end
  if type(a.lua) ~= "string" or a.lua == "" then
    return "Tool error: define_tool needs a Lua 'lua' body that returns a string"
  end
  local schema = a.input_schema
  if schema == nil or schema == json.null then schema = { type = "object", properties = {} } end
  if type(schema) ~= "table" then return "Tool error: 'input_schema' must be a JSON object" end
  -- An empty `required` decodes to an empty Lua table, which json.encode would
  -- emit as {} (an object) -- invalid JSON Schema. Drop it if empty.
  if type(schema.required) == "table" and next(schema.required) == nil then schema.required = nil end

  local ok, def = pcall(build_def, name, a.description, schema, a.lua)
  if not ok then return "Tool error: " .. tostring(def) end

  -- persist so it survives restarts and reloads
  sys.mkdir_p(tools_dir())
  local fileok, ferr = util.write_file(tools_dir() .. "/" .. name .. ".lua",
    render_tool_file(name, a.description, schema, a.lua))
  if not fileok then return "Tool error: could not save tool: " .. tostring(ferr) end

  M.registry[name] = def
  return string.format("Defined tool '%s'. It is available now and persisted to %s/%s.lua",
    name, tools_dir(), name)
end

local function tool_reload(a)
  local ok, err = bog.reload()
  if not ok then return "Tool error: reload failed (old code kept): " .. tostring(err) end
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
function M.run(name, input)
  local d = M.registry[name]
  if not d then return "Tool error: unknown tool: " .. tostring(name) end
  return d.run(input or {})
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
M.register("define_tool", {
  description = "Create a new tool at runtime by writing its Lua. The body receives a table `args` "
    .. "and must `return` a string. It may use the globals sys, io, os, json. This is how you grow "
    .. "your own capabilities.",
  input_schema = {
    type = "object",
    properties = {
      name = { type = "string", description = "tool name, [A-Za-z_][A-Za-z0-9_]*" },
      description = { type = "string" },
      input_schema = { type = "object", description = "JSON Schema for the tool's arguments" },
      lua = { type = "string", description = "Lua body; receives `args`, must return a string" },
    },
    required = { "name", "description", "lua" },
  },
  run = tool_define,
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
    if type(a.sql) ~= "string" then return "Tool error: sql requires 'sql'" end
    local params = a.params
    if params == json.null then params = nil end
    if a.write then
      local ok, r, e = pcall(bog.db.run, bog.db, a.sql, params)
      if not ok then return "Tool error: " .. tostring(r) end
      if r == nil then return "Tool error: " .. tostring(e) end
      return string.format("ok: changes=%d rowid=%d", r.changes, r.rowid)
    end
    local ok, rows, e = pcall(bog.db.query, bog.db, a.sql, params)
    if not ok then return "Tool error: " .. tostring(rows) end
    if rows == nil then return "Tool error: " .. tostring(e) end
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
      if type(a.key) ~= "string" then return "Tool error: kv set requires 'key'" end
      bog.store.kv_set(a.key, a.value or "")
      return "ok"
    elseif op == "del" then
      bog.store.kv_del(a.key or "")
      return "ok"
    elseif op == "list" then
      return json.encode(bog.store.kv_list(a.key))
    end
    return "Tool error: kv op must be get/set/del/list"
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
    if not bog.mcphost then return "Tool error: MCP host unavailable" end
    local names, err = bog.mcphost.add(a)
    if not names then return "Tool error: " .. tostring(err) end
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
    end
    return #out > 0 and table.concat(out, "\n") or "(no MCP servers connected)"
  end,
})

-- memory tools
for name, def in pairs(bog.memory.tools) do M.register(name, def) end

-- model/user-defined tool files
load_user_tools()

return M
