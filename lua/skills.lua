-- skills.lua -- a skill is a named bundle of { description, instructions, tools }.
-- Skills live under lua/skills/<name>.lua (embedded defaults, overlay-able under
-- ~/.boggart/lua/skills/). An agent's spec lists skills; resolving them yields
-- the agent's instruction text and its permitted tool allowlist.
--
-- Skills are Lua, and skills added from outside are CONVERTED to Lua rather than
-- interpreted in their original form. The ecosystem ships skills as markdown
-- (SKILL.md with YAML frontmatter), and it would be easy to teach boggart to
-- read that at runtime -- but then boggart would have two extension substrates
-- with different rules, and the markdown one would be inert: not editable by the
-- agent, not hot-reloadable, not able to compute anything. Importing compiles
-- markdown to a Lua skill file once, and from then on it is an ordinary skill
-- the agent can edit, extend and reload like the baked-in ones. One substrate.
--
-- Because it is Lua, `instructions` may also be a function(ctx) computing text
-- per agent, which a static markdown file cannot express.
local M = {}
local util = require("util") -- for to_lua's pure-data serialization of provides

-- A skill name becomes a module name (`skills.<name>`), so it must be a Lua
-- identifier. Markdown skills conventionally use hyphens; normalise them.
function M.normalize_name(name)
  if type(name) ~= "string" then return nil end
  name = name:gsub("[%-%s]+", "_"):gsub("[^%w_]", "")
  if name == "" or name:match("^%d") then return nil end
  return name
end

function M.dir()
  return bog.userdir .. "/lua/skills"
end

function M.load(name)
  local ok, mod = pcall(require, "skills." .. name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

-- Shape check. Returns nil when valid, else a reason -- so a malformed skill is
-- a loud error at author/import time rather than a silently missing tool later.
function M.validate(s)
  if type(s) ~= "table" then return "a skill must be a table" end
  if s.description ~= nil and type(s.description) ~= "string" then
    return "'description' must be a string"
  end
  local it = s.instructions
  if it ~= nil and type(it) ~= "string" and type(it) ~= "function" then
    return "'instructions' must be a string or a function"
  end
  if s.tools ~= nil then
    if type(s.tools) ~= "table" then return "'tools' must be a list of tool names" end
    for i, t in ipairs(s.tools) do
      if type(t) ~= "string" or t == "" then
        return "tools[" .. i .. "] must be a non-empty string"
      end
    end
  end
  -- provides: the described table of callable tools the skill carries. Each entry
  -- has a name and exactly one of `body` (a Lua source string, sandboxed) or
  -- `run` (a function, trusted -- only meaningful in a builtin skill file).
  if s.provides ~= nil then
    if type(s.provides) ~= "table" then return "'provides' must be a list of tool defs" end
    for i, p in ipairs(s.provides) do
      if type(p) ~= "table" then return "provides[" .. i .. "] must be a table" end
      if type(p.name) ~= "string" or not p.name:match("^[%a_][%w_]*$") then
        return "provides[" .. i .. "].name must match [A-Za-z_][A-Za-z0-9_]*"
      end
      local hasbody = type(p.body) == "string" and p.body ~= ""
      local hasrun = type(p.run) == "function"
      if hasbody == hasrun then -- both or neither
        return "provides[" .. i .. "] needs exactly one of 'body' (string) or 'run' (function)"
      end
      if p.description ~= nil and type(p.description) ~= "string" then
        return "provides[" .. i .. "].description must be a string"
      end
      if p.input_schema ~= nil and type(p.input_schema) ~= "table" then
        return "provides[" .. i .. "].input_schema must be a JSON object"
      end
    end
  end
  return nil
end

-- Every skill available, baked-in and overlay, with where it came from. Without
-- this nothing can list skills: load() needs a name you already know.
function M.list()
  local out, seen = {}, {}
  for _, mod in ipairs(boggart.embedded_names and boggart.embedded_names() or {}) do
    local n = mod:match("^skills/(.+)$")
    if n and n ~= "init" then
      out[#out + 1] = { name = n, source = "builtin" }
      seen[n] = #out
    end
  end
  local dir = M.dir()
  if sys.stat(dir) == "dir" then
    for _, fname in ipairs(sys.listdir(dir) or {}) do
      local n = fname:match("^(.+)%.lua$")
      if n then
        if seen[n] then out[seen[n]].source = "overlay (shadows builtin)"
        else out[#out + 1] = { name = n, source = "overlay" } end
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- A skill is "builtin" (trusted) only when it loads from the baked source with no
-- overlay file shadowing it -- the trust boundary for a provided `run` function.
function M.is_builtin(name)
  for _, r in ipairs(M.list()) do
    if r.name == name then return r.source == "builtin" end
  end
  return false
end

-- resolve(names) -> instructions_text, allow_set, unknown_names
--
-- The third return is the point: a misspelled skill name used to vanish -- the
-- agent silently ran without the tools it asked for, which is the hardest kind
-- of failure to notice. Callers surface `unknown` instead.
function M.resolve(names)
  local instr, allow, unknown = {}, {}, {}
  for _, n in ipairs(names or {}) do
    local s = M.load(n)
    if s then
      local it = s.instructions
      if type(it) == "function" then
        local ok, res = pcall(it)
        it = ok and res or nil
      end
      if type(it) == "string" and it ~= "" then
        instr[#instr + 1] = "## Skill: " .. n .. "\n" .. it
      end
      for _, t in ipairs(s.tools or {}) do allow[t] = true end
      -- Grant this skill's own provided tools (namespaced skill__<skill>__<tool>).
      -- resolve stays pure: it only grants NAMES; compilation into the registry is
      -- the separate materialize step (lua/tools.lua), so a bad body can never
      -- break an agent spawn -- the tool is simply absent, permission held.
      for _, p in ipairs(s.provides or {}) do
        if type(p) == "table" and type(p.name) == "string" then
          allow["skill__" .. n .. "__" .. p.name] = true
        end
      end
    else
      unknown[#unknown + 1] = n
    end
  end
  return table.concat(instr, "\n\n"), allow, unknown
end

-- ---- importing: markdown (SKILL.md) -> a Lua skill --------------------------

-- A deliberately small frontmatter reader: `key: value` pairs between --- lines,
-- which is all the Agent Skills fields use. Not a YAML parser, and not pretending
-- to be one -- anything more exotic should be edited in the Lua it compiles to.
local function parse_frontmatter(text)
  local fm, body = text:match("^%-%-%-%s*\n(.-)\n%-%-%-%s*\n(.*)$")
  if not fm then return {}, text end
  local meta = {}
  for line in (fm .. "\n"):gmatch("(.-)\n") do
    local k, v = line:match("^([%w_%-]+)%s*:%s*(.-)%s*$")
    if k then
      v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
      meta[k:lower()] = v
    end
  end
  return meta, body
end

local function split_list(v)
  if type(v) ~= "string" or v == "" then return nil end
  v = v:gsub("^%[(.*)%]$", "%1")
  local out = {}
  for raw in v:gmatch("[^,]+") do
    local item = raw:match("^%s*(.-)%s*$"):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
    if item ~= "" then out[#out + 1] = item end
  end
  return #out > 0 and out or nil
end

-- parse_markdown(text) -> skill_table, suggested_name
function M.parse_markdown(text)
  if type(text) ~= "string" or not text:match("%S") then
    return nil, "empty skill document"
  end
  local meta, body = parse_frontmatter(text)
  body = (body or ""):match("^%s*(.-)%s*$")
  local name = M.normalize_name(meta.name or "")
  local desc = meta.description
  if not desc or desc == "" then
    -- Fall back to the first heading or line, so a frontmatter-less file still
    -- imports with something useful in listings.
    desc = body:match("^#+%s*(.-)%s*\n") or body:match("^(.-)\n") or "imported skill"
  end
  local tools = split_list(meta["allowed-tools"] or meta.tools or meta.allowed_tools)
  if body == "" then return nil, "skill document has no instructions" end
  return { description = desc, instructions = body, tools = tools or {} }, name
end

-- Render a skill as a Lua module. This is the "turned into Lua" step: the result
-- is an ordinary skill file, editable and hot-reloadable like the baked ones.
function M.to_lua(name, skill, origin)
  local parts = {
    "-- skill: " .. name .. (origin and (" -- imported from " .. origin) or ""),
    "-- Compiled to Lua by skills.import so it is an ordinary boggart skill:",
    "-- edit it, add computed instructions, and `reload` to hot-swap it.",
    "return {",
    "  description = " .. string.format("%q", skill.description or name) .. ",",
  }
  local it = skill.instructions
  if type(it) == "string" and it ~= "" then
    -- A long block reads far better as [[...]] than an escaped one-liner, but
    -- only when the text cannot close the bracket itself.
    if not it:find("]]", 1, true) and not it:find("\\", 1, true) then
      parts[#parts + 1] = "  instructions = [[\n" .. it .. "\n]],"
    else
      parts[#parts + 1] = "  instructions = " .. string.format("%q", it) .. ","
    end
  end
  local tools = skill.tools or {}
  if #tools > 0 then
    local q = {}
    for i, t in ipairs(tools) do q[i] = string.format("%q", t) end
    parts[#parts + 1] = "  tools = { " .. table.concat(q, ", ") .. " },"
  else
    parts[#parts + 1] = "  tools = {},"
  end
  -- provides: emitted as PURE DATA -- `body` as a quoted string, schema via
  -- util.serialize. A `run` function is not serializable, so a saved/round-tripped
  -- skill can only ever carry sandboxed bodies (raw closures live solely in the
  -- baked, in-repo skill files). This is the structural half of the trust boundary.
  local provides = skill.provides or {}
  local pd = {}
  for _, p in ipairs(provides) do
    if type(p.body) == "string" then
      pd[#pd + 1] = "    {"
      pd[#pd + 1] = "      name = " .. string.format("%q", p.name) .. ","
      pd[#pd + 1] = "      description = " .. string.format("%q", p.description or p.name) .. ","
      pd[#pd + 1] = "      input_schema = " ..
        util.serialize(p.input_schema or { type = "object", properties = {} }) .. ","
      pd[#pd + 1] = "      body = " .. string.format("%q", p.body) .. ","
      pd[#pd + 1] = "    },"
    end
  end
  if #pd > 0 then
    parts[#parts + 1] = "  provides = {"
    for _, l in ipairs(pd) do parts[#parts + 1] = l end
    parts[#parts + 1] = "  },"
  end
  parts[#parts + 1] = "}"
  parts[#parts + 1] = ""
  return table.concat(parts, "\n")
end

-- Persist a skill as Lua under the overlay, and make it live immediately by
-- dropping the stale module from package.loaded.
function M.save(name, skill, origin)
  local err = M.validate(skill)
  if err then return nil, err end
  local dir = M.dir()
  sys.mkdir_p(dir)
  local path = dir .. "/" .. name .. ".lua"
  local src = M.to_lua(name, skill, origin)
  -- Compile before writing: never persist a skill file that will not load.
  local chunk, cerr = load(src, "@skill:" .. name)
  if not chunk then return nil, "generated skill does not compile: " .. tostring(cerr) end
  local f, ferr = io.open(path, "w")
  if not f then return nil, "cannot write " .. path .. ": " .. tostring(ferr) end
  f:write(src)
  f:close()
  package.loaded["skills." .. name] = nil
  -- Make provided tools live immediately: re-materialize this one skill (compiles
  -- new/changed bodies into the registry and prunes any it dropped). Guarded --
  -- during early boot `tools` may not be wired yet; the load-time materialize
  -- covers that case.
  local ok, T = pcall(require, "tools")
  if ok and T and T.materialize_skill then pcall(T.materialize_skill, name) end
  return path
end

-- import(text, name_hint, origin) -> name, path | nil, err
function M.import(text, name_hint, origin)
  local skill, name_or_err = M.parse_markdown(text)
  if not skill then return nil, name_or_err end
  local name = M.normalize_name(name_hint or "") or name_or_err
  if not name then return nil, "could not determine a skill name; pass one" end
  local path, err = M.save(name, skill, origin)
  if not path then return nil, err end
  return name, path
end

-- ---- the tools the model is offered ----------------------------------------

M.tools = {
  skills = {
    description = "List available skills (baked-in and your own), with where each came "
      .. "from. A skill bundles instructions plus the tools an agent is allowed to use; "
      .. "name them when you spawn a sub-agent.",
    input_schema = { type = "object",
      properties = { name = { type = "string", description = "show one skill in full" } } },
    run = function(a)
      if type(a.name) == "string" and a.name ~= "" then
        local s = M.load(a.name)
        if not s then return "Tool error: [tool_not_found] no skill named '" .. a.name .. "'" end
        local it = s.instructions
        if type(it) == "function" then it = "(computed at resolve time)" end
        return string.format("%s\n%s\n\ntools: %s\n\n%s", a.name,
          s.description or "", table.concat(s.tools or {}, ", "), tostring(it or ""))
      end
      local rows = M.list()
      if #rows == 0 then return "(no skills)" end
      local out = {}
      for _, r in ipairs(rows) do
        local s = M.load(r.name)
        out[#out + 1] = string.format("%-16s %-22s %s", r.name, r.source,
          (s and s.description) or "?")
      end
      return table.concat(out, "\n")
    end,
  },

  define_skill = {
    description = "Author a skill and persist it as Lua: a name, a description, the "
      .. "instructions an agent following it should have, the tools it may use, and "
      .. "optionally `provides` -- its OWN callable tools, so a skill is a code "
      .. "package, not just prose. Each provides entry is { name, description, "
      .. "input_schema, body }, where body is Lua that receives `args` and returns a "
      .. "string; it compiles through the same sandbox as define_tool and is offered "
      .. "to any agent granted the skill as skill__<skill>__<tool>. define_tool's "
      .. "counterpart for behaviour: promote a way of working AND the code it needs.",
    input_schema = { type = "object",
      properties = {
        name = { type = "string" },
        description = { type = "string" },
        instructions = { type = "string" },
        tools = { type = "array", items = { type = "string" } },
        provides = { type = "array", items = { type = "object", properties = {
          name = { type = "string" },
          description = { type = "string" },
          input_schema = { type = "object" },
          body = { type = "string", description = "Lua body; receives `args`, returns a string" },
        }, required = { "name", "body" } } },
      }, required = { "name", "instructions" } },
    run = function(a)
      local name = M.normalize_name(a.name)
      if not name then return "Tool error: [validation_error] invalid skill name" end
      -- Compile-check each provided body up front, so a broken body is fixable
      -- input to define_skill (like tool_define), never a persisted dud.
      local T = require("tools")
      for _, p in ipairs(a.provides or {}) do
        local ok, err = pcall(T.build_def, p.name, p.description or p.name, p.input_schema, p.body)
        if not ok then
          return "Tool error: [validation_error] provides '" .. tostring(p.name) .. "': "
            .. (tostring(err):gsub("^.-tool body compile error: ", ""))
        end
      end
      local skill = { description = a.description or name, instructions = a.instructions,
                      tools = a.tools or {}, provides = a.provides or {} }
      local path, err = M.save(name, skill)
      if not path then return "Tool error: [validation_error] " .. tostring(err) end
      return string.format("Defined skill '%s' (%d tools, %d provided). Written as Lua to %s",
        name, #(a.tools or {}), #(a.provides or {}), path)
    end,
  },

  import_skill = {
    description = "Import a skill written as markdown (a SKILL.md with YAML frontmatter, "
      .. "the ecosystem's format) by COMPILING it to a boggart Lua skill. Give a 'path' "
      .. "to read, or the 'text' itself. After import it is an ordinary skill you can "
      .. "edit and reload.",
    input_schema = { type = "object",
      properties = {
        path = { type = "string", description = "path to a SKILL.md" },
        text = { type = "string", description = "the markdown itself" },
        name = { type = "string", description = "override the skill name" },
      } },
    run = function(a)
      local text, origin = a.text, "text"
      if type(a.path) == "string" and a.path ~= "" then
        local f = io.open(a.path, "r")
        if not f then return "Tool error: [host_capability_error] cannot read " .. a.path end
        text = f:read("a"); f:close(); origin = a.path
      end
      if type(text) ~= "string" or text == "" then
        return "Tool error: [validation_error] import_skill needs 'path' or 'text'"
      end
      local name, path = M.import(text, a.name, origin)
      if not name then return "Tool error: [validation_error] " .. tostring(path) end
      return string.format("Imported skill '%s', compiled to Lua at %s", name, path)
    end,
  },
}

return M
