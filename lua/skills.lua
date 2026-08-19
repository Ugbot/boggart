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
  -- Fall back to a DB-stored skill (store="db"). Its source is the SAME pure-data
  -- Lua as a file skill, so loading it is as safe as requiring a file. Positive-
  -- cache the compiled table; M.save drops the entry on edit.
  M._dbcache = M._dbcache or {}
  if M._dbcache[name] then return M._dbcache[name] end
  local okk, src = pcall(function()
    return bog.store and bog.store.kv_get and bog.store.kv_get("skill:" .. name)
  end)
  if okk and type(src) == "string" and src ~= "" then
    local chunk = load(src, "@skill:" .. name)
    if chunk then
      local sok, res = pcall(chunk)
      if sok and type(res) == "table" then M._dbcache[name] = res; return res end
    end
  end
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
  -- invocation: who may reach for this skill.
  --   "model" -- the agent (and find_skill) may adopt it when the task fits
  --   "user"  -- only when the user explicitly grants it (slash / spawn skills=)
  -- Absent means "model" for discoverability; capability packs (core, …) omit it.
  if s.invocation ~= nil then
    if s.invocation ~= "model" and s.invocation ~= "user" then
      return "'invocation' must be \"model\" or \"user\""
    end
  end
  -- fallback: another skill (or list of skills) whose tools are granted as
  -- backups when this one's preferred tools are unavailable.
  if s.fallback ~= nil then
    if type(s.fallback) == "table" then
      for i, f in ipairs(s.fallback) do
        if type(f) ~= "string" or f == "" then
          return "fallback[" .. i .. "] must be a non-empty skill name"
        end
      end
    elseif type(s.fallback) ~= "string" then
      return "'fallback' must be a skill name or a list of skill names"
    end
  end
  -- provides: the described table of callable tools the skill carries. Each entry
  -- has a name and exactly one of `body` (a Lua source string, sandboxed) or
  -- `run` (a function, trusted -- only meaningful in a builtin skill file).
  -- provides is a TABLE KEYED BY TOOL NAME (like a described namespace); each
  -- value is { description, input_schema, run|body }. This mirrors how MCP tools
  -- are managed -- namespaced and registered as ordinary tools, granted with a
  -- wildcard -- only here the namespace is skill__<skill>__<tool>.
  if s.provides ~= nil then
    if type(s.provides) ~= "table" then
      return "'provides' must be a table of tool defs keyed by name"
    end
    for tname, p in pairs(s.provides) do
      if type(tname) ~= "string" or not tname:match("^[%a_][%w_]*$") then
        return "provides key '" .. tostring(tname) .. "' must match [A-Za-z_][A-Za-z0-9_]*"
      end
      if type(p) ~= "table" then return "provides['" .. tname .. "'] must be a table" end
      local hasbody = type(p.body) == "string" and p.body ~= ""
      local hasrun = type(p.run) == "function"
      if hasbody == hasrun then -- both or neither
        return "provides['" .. tname .. "'] needs exactly one of 'body' (string) or 'run' (function)"
      end
      if p.description ~= nil and type(p.description) ~= "string" then
        return "provides['" .. tname .. "'].description must be a string"
      end
      if p.input_schema ~= nil and type(p.input_schema) ~= "table" then
        return "provides['" .. tname .. "'].input_schema must be a JSON object"
      end
    end
  end

  -- verify: names a tool (usually one this skill `provides`) that CHECKS the
  -- skill's outcome -- the mechanical "did it actually work?" pass. resolve()
  -- appends a standard "run it before you finish, and fix what it flags" nudge
  -- to the skill's instructions, so verification is a first-class part of a
  -- skill rather than prose each one hand-writes. String = the tool name;
  -- { tool = <name>, nudge? = <custom text> } to override the wording.
  if s.verify ~= nil then
    local v = s.verify
    local vtool = (type(v) == "string" and v) or (type(v) == "table" and v.tool)
    if type(vtool) ~= "string" or vtool == "" then
      return "'verify' must be a tool name (string) or { tool = <name>, nudge? = <text> }"
    end
    if type(v) == "table" and v.nudge ~= nil and type(v.nudge) ~= "string" then
      return "verify.nudge must be a string"
    end
    -- The named tool must be one the skill actually carries, so the agent can
    -- call it: either a provided tool or something in the granted tools list.
    local known = type(s.provides) == "table" and s.provides[vtool] ~= nil
    if not known and type(s.tools) == "table" then
      for _, t in ipairs(s.tools) do if t == vtool then known = true break end end
    end
    if not known then
      return "verify tool '" .. vtool .. "' is not in this skill's provides or tools"
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
  -- DB-stored skills (store="db"). A file/builtin of the same name shadows them
  -- (M.load tries require first), so only surface DB skills without a file.
  local okk, rows = pcall(function()
    return bog.store and bog.store.kv_list and bog.store.kv_list("skill:")
  end)
  if okk and type(rows) == "table" then
    for _, r in ipairs(rows) do
      local n = tostring(r.key):match("^skill:(.+)$")
      if n and not seen[n] then
        out[#out + 1] = { name = n, source = "database" }
        seen[n] = #out
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
-- Grant a skill's tool allow-list + its provided-tools namespace wildcard.
local function grant_tools(s, n, allow)
  for _, t in ipairs(s.tools or {}) do allow[t] = true end
  -- Grant this skill's own provided tools with ONE wildcard over its namespace
  -- -- exactly how a skill grants a whole MCP server (mcp__<server>__*). resolve
  -- stays pure: it only grants; the separate materialize step (lua/tools.lua)
  -- compiles the bodies, so a bad body can never break an agent spawn.
  if type(s.provides) == "table" and next(s.provides) then
    allow["skill__" .. n .. "__*"] = true
  end
end

function M.resolve(names)
  local instr, allow, unknown = {}, {}, {}
  local seen = {}

  -- A skill may name FALLBACK skills (`fallback = "x"` or `{ "x", "y" }`). Their
  -- tools are also granted, as backups: if a preferred tool is absent (an MCP
  -- server that is down, a binary not installed), the agent still has a built-in
  -- path. A fallback contributes TOOLS, not a second set of instructions the
  -- model would have to reconcile. Cycles and repeats are guarded by `seen`.
  local function fold(n, is_fallback)
    if seen[n] then return end
    seen[n] = true
    local s = M.load(n)
    if not s then
      if not is_fallback then unknown[#unknown + 1] = n end
      return
    end
    if not is_fallback then
      local it = s.instructions
      if type(it) == "function" then
        local ok, res = pcall(it)
        it = ok and res or nil
      end
      if type(it) == "string" and it ~= "" then
        instr[#instr + 1] = "## Skill: " .. n .. "\n" .. it
      end
      -- Verification is first-class: if the skill names a verify tool, tell the
      -- agent to run it on its own output and fix what it reports before it can
      -- call the work done -- the same discipline every skill should share.
      local v = s.verify
      if v then
        local vtool = (type(v) == "string" and v) or v.tool
        local nudge = (type(v) == "table" and v.nudge)
          or ("Before you report this skill's work as done, run `" .. vtool
              .. "` on your output and FIX everything it flags; re-run until it "
              .. "passes. Never claim success on an unverified result.")
        instr[#instr + 1] = "### Verify \u{2014} " .. n .. "\n" .. nudge
      end
    end
    grant_tools(s, n, allow)
    local fb = s.fallback
    if type(fb) == "string" then fold(fb, true)
    elseif type(fb) == "table" then for _, f in ipairs(fb) do fold(f, true) end end
  end

  for _, n in ipairs(names or {}) do fold(n, false) end
  return table.concat(instr, "\n\n"), allow, unknown
end

-- lint(name) -> { name, ok, issues, has_checker, has_verify }. Checks a skill
-- against the canonical template (docs/skills-and-tools.md): a real description,
-- instructions, and -- the point -- that a skill which PROVIDES a checker also
-- names it as `verify`, and that `verify` names a tool the skill actually
-- carries. Pure-capability skills (no checker) legitimately have no verify.
local CHECKER_PAT = { "check", "verify", "audit", "lint", "validate", "^test", "score", "grade" }
local function looks_like_checker(tname)
  for _, p in ipairs(CHECKER_PAT) do if tname:match(p) then return true end end
  return false
end
function M.lint(name)
  local s = M.load(name)
  if not s then return { name = name, ok = false, issues = { "skill not found" } } end
  local issues = {}
  if type(s.description) ~= "string" or #s.description < 12 then
    issues[#issues + 1] = "description missing or too terse (say WHAT it is and WHEN to use it)"
  end
  local it = s.instructions
  if type(it) == "function" then local ok, r = pcall(it); it = ok and r or "" end
  if type(it) ~= "string" or not it:match("%S") then
    issues[#issues + 1] = "instructions missing or empty"
  end
  local checker
  if type(s.provides) == "table" then
    for tname in pairs(s.provides) do if looks_like_checker(tname) then checker = checker or tname end end
  end
  local vtool = (type(s.verify) == "string" and s.verify)
             or (type(s.verify) == "table" and s.verify.tool) or nil
  if checker and not vtool then
    issues[#issues + 1] = "provides a checker ('" .. checker .. "') but has no `verify` slot"
  end
  if vtool then
    local ok = type(s.provides) == "table" and s.provides[vtool] ~= nil
    if not ok and type(s.tools) == "table" then
      for _, t in ipairs(s.tools) do if t == vtool then ok = true break end end
    end
    if not ok then issues[#issues + 1] = "verify names '" .. vtool .. "' which the skill neither provides nor grants" end
  end
  return { name = name, ok = #issues == 0, issues = issues,
           has_checker = checker ~= nil, has_verify = vtool ~= nil }
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

-- Pull a "## Tools" section out of the markdown body into a `provides` map. Each
-- "### <name>" subsection becomes a tool: its prose is the description, its fenced
-- ```lua block is the body (sandboxed like any model-authored code). Returns
-- (provides, body_without_the_tools_section). This is the markdown convention that
-- lets an imported .md skill carry code, not just prose.
local function extract_tools(body)
  local hs, he = body:find("\n?##%s+[Tt]ools%s*\n")
  if not hs then return {}, body end
  local rest = body:sub(he + 1)
  local nexth = rest:find("\n##%s+%S")           -- a later level-2 heading ends the section
  local section = nexth and rest:sub(1, nexth - 1) or rest
  local tail = nexth and rest:sub(nexth) or ""
  local instructions = (body:sub(1, hs - 1) .. "\n" .. tail):gsub("^%s+", ""):gsub("%s+$", "")

  local provides = {}
  local i = 1
  while true do
    local ns, ne, nm = section:find("###%s+([%w_%- ]-)%s*\n", i)
    if not ns then break end
    local srest = section:sub(ne + 1)
    local nn = srest:find("\n###%s")
    local sub = nn and srest:sub(1, nn - 1) or srest
    i = ne + (nn or #srest)
    local lua = sub:match("```lua%s*\n(.-)\n```") or sub:match("```%s*\n(.-)\n```")
    if lua and lua:match("%S") then
      -- description = the prose in the subsection, with the code fence removed
      local desc = sub:gsub("```.-```", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      local tname = M.normalize_name(nm)
      if tname then
        provides[tname] = { description = (desc ~= "" and desc) or tname, body = lua }
      end
    end
  end
  return provides, instructions
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
  -- A "## Tools" section becomes the skill's `provides` (code); the rest is prose.
  local provides, instructions = extract_tools(body)
  if instructions == "" then return nil, "skill document has no instructions" end
  -- `verify: <tool>` frontmatter makes outcome-checking first-class (usually one
  -- of the ## Tools this document provides); resolve appends the standard nudge.
  local verify = meta.verify
  if verify == "" then verify = nil end
  -- Matt Pocock / Agent Skills: disable-model-invocation: true => user-only.
  local invocation
  local dmi = meta["disable-model-invocation"] or meta.disable_model_invocation
  if dmi == "true" or dmi == true or dmi == "yes" then
    invocation = "user"
  elseif meta.invocation == "model" or meta.invocation == "user" then
    invocation = meta.invocation
  end
  return { description = desc, instructions = instructions, tools = tools or {},
           provides = provides, verify = verify, invocation = invocation }, name
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
  if skill.invocation == "model" or skill.invocation == "user" then
    parts[#parts + 1] = "  invocation = " .. string.format("%q", skill.invocation) .. ","
  end
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
  -- fallback skills (backup tool sources), if declared
  local fb = skill.fallback
  if type(fb) == "string" then
    parts[#parts + 1] = "  fallback = " .. string.format("%q", fb) .. ","
  elseif type(fb) == "table" and #fb > 0 then
    local q = {}
    for i, f in ipairs(fb) do q[i] = string.format("%q", f) end
    parts[#parts + 1] = "  fallback = { " .. table.concat(q, ", ") .. " },"
  end
  -- verify: the outcome-check tool (string), or { tool, nudge } for custom wording.
  local vf = skill.verify
  if type(vf) == "string" then
    parts[#parts + 1] = "  verify = " .. string.format("%q", vf) .. ","
  elseif type(vf) == "table" and type(vf.tool) == "string" then
    parts[#parts + 1] = "  verify = { tool = " .. string.format("%q", vf.tool)
      .. (vf.nudge and (", nudge = " .. string.format("%q", vf.nudge)) or "") .. " },"
  end
  -- provides: emitted as PURE DATA -- `body` as a quoted string, schema via
  -- util.serialize. A `run` function is not serializable, so a saved/round-tripped
  -- skill can only ever carry sandboxed bodies (raw closures live solely in the
  -- baked, in-repo skill files). This is the structural half of the trust boundary.
  -- Keyed by name, sorted so the file is stable across saves.
  local provides = skill.provides or {}
  local names = {}
  for tname, p in pairs(provides) do
    if type(p) == "table" and type(p.body) == "string" then names[#names + 1] = tname end
  end
  table.sort(names)
  if #names > 0 then
    parts[#parts + 1] = "  provides = {"
    for _, tname in ipairs(names) do
      local p = provides[tname]
      parts[#parts + 1] = "    [" .. string.format("%q", tname) .. "] = {"
      parts[#parts + 1] = "      description = " .. string.format("%q", p.description or tname) .. ","
      parts[#parts + 1] = "      input_schema = " ..
        util.serialize(p.input_schema or { type = "object", properties = {} }) .. ","
      parts[#parts + 1] = "      body = " .. string.format("%q", p.body) .. ","
      parts[#parts + 1] = "    },"
    end
    parts[#parts + 1] = "  },"
  end
  parts[#parts + 1] = "}"
  parts[#parts + 1] = ""
  return table.concat(parts, "\n")
end

-- Persist a skill as Lua, and make it live immediately. `store` is "file" (the
-- default -- a Lua file under the overlay, editable + hot-reloadable) or "db"
-- (the same Lua source in the SQLite kv store, under key skill:<name> -- portable,
-- travels with the store, no stray files). Either way the payload is the SAME
-- pure-data Lua the skill is compiled from, so the two backends are interchangeable.
function M.save(name, skill, origin, store)
  local err = M.validate(skill)
  if err then return nil, err end
  local src = M.to_lua(name, skill, origin)
  -- Compile before persisting: never store a skill that will not load.
  local chunk, cerr = load(src, "@skill:" .. name)
  if not chunk then return nil, "generated skill does not compile: " .. tostring(cerr) end

  local where
  if store == "db" then
    if not (bog.store and bog.store.kv_set) then return nil, "the store is not open" end
    bog.store.kv_set("skill:" .. name, src)
    M._dbcache = M._dbcache or {}; M._dbcache[name] = nil -- drop the cached table
    where = "Stored skill '" .. name .. "' in the database."
  else
    local dir = M.dir()
    sys.mkdir_p(dir)
    local path = dir .. "/" .. name .. ".lua"
    local f, ferr = io.open(path, "w")
    if not f then return nil, "cannot write " .. path .. ": " .. tostring(ferr) end
    f:write(src); f:close()
    where = "Written as Lua to " .. path
  end
  package.loaded["skills." .. name] = nil
  -- Make provided tools live immediately: re-materialize this one skill (compiles
  -- new/changed bodies into the registry and prunes any it dropped). Guarded --
  -- during early boot `tools` may not be wired yet; the load-time materialize
  -- covers that case.
  local ok, T = pcall(require, "tools")
  if ok and T and T.materialize_skill then pcall(T.materialize_skill, name) end
  return where
end

-- import(text, name_hint, origin, store) -> name, where | nil, err
function M.import(text, name_hint, origin, store)
  local skill, name_or_err = M.parse_markdown(text)
  if not skill then return nil, name_or_err end
  local name = M.normalize_name(name_hint or "") or name_or_err
  if not name then return nil, "could not determine a skill name; pass one" end
  local where, err = M.save(name, skill, origin, store)
  if not where then return nil, err end
  return name, where
end

-- ---- the tools the model is offered ----------------------------------------

M.tools = {
  skills = {
    description = "List available skills (baked-in and your own), with where each came "
      .. "from. A skill bundles instructions plus the tools an agent is allowed to use; "
      .. "name them when you spawn a sub-agent.",
    input_schema = { type = "object",
      properties = { name = { type = "string", description = "show one skill in full" },
        lint = { type = "boolean", description = "instead of listing, report each skill's "
          .. "conformance to the skill template (docs/skills-and-tools.md): description, "
          .. "instructions, and whether a skill that provides a checker names it as `verify`" } } },
    run = function(a)
      if a.lint then
        local names = {}
        if type(a.name) == "string" and a.name ~= "" then names = { a.name }
        else for _, r in ipairs(M.list()) do names[#names + 1] = r.name end; table.sort(names) end
        local out = {}
        for _, n in ipairs(names) do
          local r = M.lint(n)
          out[#out + 1] = string.format("%-4s %-16s %s", r.ok and "OK" or "FAIL", n,
            (#r.issues > 0) and table.concat(r.issues, "; ")
              or (r.has_verify and "[verify]" or (r.has_checker and "[checker]" or "")))
        end
        return table.concat(out, "\n")
      end
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
        local inv = (s and s.invocation) or "model"
        out[#out + 1] = string.format("%-16s %-6s %-22s %s", r.name, inv, r.source,
          (s and s.description) or "?")
      end
      return table.concat(out, "\n")
    end,
  },

  define_skill = {
    description = "Author a skill and persist it as Lua: a name, a description, the "
      .. "instructions an agent following it should have, the tools it may use, and "
      .. "optionally `provides` -- its OWN callable tools, so a skill is a code "
      .. "package, not just prose. `provides` is an object KEYED BY TOOL NAME; each "
      .. "value is { description, input_schema, body } where body is Lua that receives "
      .. "`args` and returns a string. Provided tools compile through the same sandbox "
      .. "as define_tool and are offered to any agent granted the skill as "
      .. "skill__<skill>__<tool> (granted with a wildcard, like an MCP server). Pass "
      .. "`verify` = the name of a check tool (usually one you provide) to make outcome "
      .. "verification a first-class part of the skill. A provided tool's body can share "
      .. "state with a skill's instructions via the `data` capability (data.put/get over "
      .. "~/.boggart/data), e.g. the rules live once and both the writer and the checker "
      .. "read them -- the single-source pattern. Pass store=\"db\" to persist into the "
      .. "database instead of a Lua file. Follow the canonical anatomy in "
      .. "docs/skills-and-tools.md (run the `skills` tool with lint=true to check "
      .. "conformance).",
    input_schema = { type = "object",
      properties = {
        name = { type = "string" },
        description = { type = "string" },
        instructions = { type = "string" },
        tools = { type = "array", items = { type = "string" } },
        provides = { type = "object", description = "tools keyed by name",
          additionalProperties = { type = "object", properties = {
            description = { type = "string" },
            input_schema = { type = "object" },
            body = { type = "string", description = "Lua body; receives `args`, returns a string" },
          }, required = { "body" } } },
        verify = { type = "string", description = "name of a tool (usually one this "
          .. "skill `provides`) that CHECKS the skill's outcome -- the mechanical "
          .. "'did it actually work?' pass. boggart appends a standard 'run it and fix "
          .. "everything it flags before you finish' nudge to the instructions, so "
          .. "verification is part of the skill, not prose you rewrite each time." },
        invocation = { type = "string", enum = { "model", "user" },
          description = "who may reach for this skill: \"model\" (default discoverable "
            .. "via find_skill) or \"user\" (only when explicitly granted)" },
        store = { type = "string", enum = { "file", "db" },
          description = "where to persist (default file)" },
      }, required = { "name", "instructions" } },
    run = function(a)
      local name = M.normalize_name(a.name)
      if not name then return "Tool error: [validation_error] invalid skill name" end
      -- Compile-check each provided body up front, so a broken body is fixable
      -- input to define_skill (like tool_define), never a persisted dud.
      local T, nprov = require("tools"), 0
      for tname, p in pairs(a.provides or {}) do
        nprov = nprov + 1
        if type(p) ~= "table" or type(p.body) ~= "string" then
          return "Tool error: [validation_error] provides '" .. tostring(tname)
            .. "' must be a table with a Lua 'body'"
        end
        local ok, err = pcall(T.build_def, tname, p.description or tname, p.input_schema, p.body)
        if not ok then
          return "Tool error: [validation_error] provides '" .. tostring(tname) .. "': "
            .. (tostring(err):gsub("^.-tool body compile error: ", ""))
        end
      end
      local skill = { description = a.description or name, instructions = a.instructions,
                      tools = a.tools or {}, provides = a.provides or {}, verify = a.verify,
                      invocation = a.invocation }
      local path, err = M.save(name, skill, nil, a.store)
      if not path then return "Tool error: [validation_error] " .. tostring(err) end
      return string.format("Defined skill '%s' (%d tools, %d provided). %s",
        name, #(a.tools or {}), nprov, path)
    end,
  },

  import_skill = {
    description = "Import a skill written as markdown (a SKILL.md with YAML frontmatter, "
      .. "the ecosystem's format) by COMPILING it to a boggart Lua skill -- one substrate. "
      .. "A `## Tools` section becomes the skill's code: each `### <name>` subsection with a "
      .. "```lua fenced block becomes a provided tool (its prose is the description, the fence "
      .. "is the body, compiled sandboxed). Give a 'path' to read or the 'text' itself; pass "
      .. "store=\"db\" to keep it in the database. After import it is an ordinary editable skill.",
    input_schema = { type = "object",
      properties = {
        path = { type = "string", description = "path to a SKILL.md" },
        text = { type = "string", description = "the markdown itself" },
        name = { type = "string", description = "override the skill name" },
        store = { type = "string", enum = { "file", "db" }, description = "where to persist (default file)" },
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
      local name, where = M.import(text, a.name, origin, a.store)
      if not name then return "Tool error: [validation_error] " .. tostring(where) end
      local s = M.load(name)
      local nprov = 0
      for _ in pairs((s and s.provides) or {}) do nprov = nprov + 1 end
      return string.format("Imported skill '%s' (%d provided tool%s). %s",
        name, nprov, nprov == 1 and "" or "s", where)
    end,
  },
}

return M
