-- project.lua -- the unit of context.
--
-- A project is NAMED, not a directory, and owns zero or more roots. Git is used
-- where a root is a repo and everything else still works where it is not, so a
-- story project is as real as a codebase. It scopes memory, chats, skills,
-- tools and search.
--
-- `global` is itself a project rather than a separate tier: the loose chat you
-- have when you are not working on anything in particular. Every project reads
-- it, ranked below its own results; no project reads another. That single rule
-- is the whole isolation model, and it lives in lua/store.lua's SQL rather than
-- being reimplemented per caller.
--
-- The current project defaults to `global`, so someone who never says the word
-- "project" gets exactly today's behaviour with a name attached to it.
--
-- Design and the interview that settled it: docs/projects.md.
local M = {}

M.GLOBAL = "global"

-- ---------------------------------------------------------------------------
-- the current project
-- ---------------------------------------------------------------------------

function M.current()
  if type(bog) ~= "table" then return M.GLOBAL end
  bog.project = bog.project or M.GLOBAL
  return bog.project
end

function M.is_global(name) return (name or M.current()) == M.GLOBAL end

-- Switch. Returns the project row, or nil + why. Never creates: naming a
-- project you have not made is a typo far more often than an intention.
function M.switch(name)
  if not name or name == "" then return nil, "which project?" end
  if name ~= M.GLOBAL and not M.get(name) then
    return nil, "no project called '" .. name .. "' (`/project new " .. name .. "` makes one)"
  end
  local from = M.current()
  bog.project = name
  bog.events.emit("project:switched", { from = from, to = name })
  return M.get(name) or { name = M.GLOBAL, roots = {} }
end

-- ---------------------------------------------------------------------------
-- rows
-- ---------------------------------------------------------------------------

function M.get(name)
  if not (bog.db and name) then return nil end
  if name == M.GLOBAL then
    local ok, row = pcall(bog.store.project_get, M.GLOBAL)
    return (ok and row) or { name = M.GLOBAL, label = "loose chat", roots = {} }
  end
  local ok, row = pcall(bog.store.project_get, name)
  return ok and row or nil
end

function M.list()
  if not bog.db then return {} end
  local ok, rows = pcall(bog.store.project_list)
  return ok and rows or {}
end

-- Names are keys: lowercase, no spaces, so they can be typed, completed and put
-- in a manifest without quoting.
function M.normalize(name)
  return tostring(name or ""):lower():gsub("%s+", "-"):gsub("[^%w%-_.]", "")
end

function M.create(name, roots, label)
  name = M.normalize(name)
  if name == "" then return nil, "a project needs a name" end
  if M.get(name) then return nil, "'" .. name .. "' already exists" end
  local abs = {}
  for _, r in ipairs(roots or {}) do
    local full = M.abspath(r)
    if full then abs[#abs + 1] = full end
  end
  bog.store.project_put(name, { label = label, roots = abs })
  bog.events.emit("project:created", { name = name, roots = abs })
  return M.get(name)
end

function M.delete(name)
  if name == M.GLOBAL then return nil, "global cannot be deleted" end
  if not M.get(name) then return nil, "no project called '" .. name .. "'" end
  -- Its chats and memories come home to global rather than vanishing: deleting
  -- a project must not silently delete a year of conversation.
  local moved = bog.store.project_absorb(name)
  bog.store.project_del(name)
  if M.current() == name then bog.project = M.GLOBAL end
  bog.events.emit("project:deleted", { name = name, absorbed = moved })
  return moved
end

-- ---------------------------------------------------------------------------
-- roots
-- ---------------------------------------------------------------------------

function M.abspath(p)
  if type(p) ~= "string" or p == "" then return nil end
  if p:sub(1, 1) == "/" then return (p:gsub("/+$", "")) end
  local cwd = sys.cwd() or "."
  if p == "." then return cwd end
  return ((cwd .. "/" .. p):gsub("/+$", ""))
end

function M.roots(name)
  local p = M.get(name or M.current())
  return (p and p.roots) or {}
end

function M.add_root(name, dir)
  name = name or M.current()
  if name == M.GLOBAL then return nil, "global has no roots" end
  local p = M.get(name)
  if not p then return nil, "no project called '" .. tostring(name) .. "'" end
  local full = M.abspath(dir)
  if not full then return nil, "not a path: " .. tostring(dir) end
  if sys.stat(full) ~= "dir" then return nil, full .. " is not a directory" end
  for _, r in ipairs(p.roots) do if r == full then return p.roots end end
  p.roots[#p.roots + 1] = full
  bog.store.project_put(name, { roots = p.roots })
  bog.events.emit("project:roots", { name = name, roots = p.roots })
  return p.roots
end

function M.remove_root(name, dir)
  name = name or M.current()
  local p = M.get(name)
  if not p then return nil, "no project called '" .. tostring(name) .. "'" end
  local full = M.abspath(dir)
  local out = {}
  for _, r in ipairs(p.roots) do if r ~= full then out[#out + 1] = r end end
  bog.store.project_put(name, { roots = out })
  return out
end

-- Is `path` inside any of this project's roots? Used for the working boundary
-- and for adoption below.
function M.owns(path, name)
  local full = M.abspath(path)
  if not full then return false end
  for _, r in ipairs(M.roots(name)) do
    if full == r or full:sub(1, #r + 1) == (r .. "/") then return true end
  end
  return false
end

-- The project (if exactly one) whose roots contain `dir`.
--
-- Exactly one on purpose: with two projects claiming the same directory there
-- is no right answer, and guessing would put work in the wrong place silently.
-- Ambiguity returns nil and the caller stays where it is.
function M.for_directory(dir)
  local full = M.abspath(dir or (sys.cwd() or "."))
  local hits = {}
  for _, p in ipairs(M.list()) do
    if p.name ~= M.GLOBAL then
      for _, r in ipairs(p.roots or {}) do
        if full == r or full:sub(1, #r + 1) == (r .. "/") then
          hits[#hits + 1] = p.name
          break
        end
      end
    end
  end
  if #hits == 1 then return hits[1] end
  return nil, #hits
end

-- Adopt the project that owns the working directory, at startup. Proposed
-- behaviour from docs/projects.md (BPROJ-8): an unambiguous match switches,
-- anything else leaves you in `global` rather than guessing.
function M.adopt_cwd()
  if not bog.db then return nil end
  local name, n = M.for_directory(sys.cwd())
  if name then
    bog.project = name
    bog.events.emit("project:adopted", { name = name })
    return name
  end
  if n and n > 1 then
    bog.events.emit("project:ambiguous", { count = n, dir = sys.cwd() })
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- the manifest: how a project travels between machines
-- ---------------------------------------------------------------------------
--
-- Skills stay in boggart. The project's first root carries a SHOPPING LIST --
-- `.boggart/project.json` -- naming what it expects, so on another machine
-- boggart can say what is missing. It never contains skill bodies, and boggart
-- never installs anything from it on its own: a repo that could silently add
-- executable behaviour to your agent by being cloned is a repo that has taken a
-- decision away from you.
--
-- Same rule as the model catalog: the store is the truth, the file is the
-- exchange format.
M.MANIFEST = ".boggart/project.json"

function M.manifest_path(name)
  local roots = M.roots(name)
  if #roots == 0 then return nil end
  return roots[1] .. "/" .. M.MANIFEST
end

-- Relative roots where they sit under the first one, so a manifest committed on
-- one machine still means something on another where the checkout lives
-- elsewhere.
local function relative_roots(roots)
  local out, base = {}, roots[1]
  for _, r in ipairs(roots) do
    if r == base then out[#out + 1] = "."
    elseif base and r:sub(1, #base + 1) == (base .. "/") then out[#out + 1] = r:sub(#base + 2)
    else out[#out + 1] = r end
  end
  return out
end

function M.write_manifest(name)
  name = name or M.current()
  if name == M.GLOBAL then return nil, "global has no manifest" end
  local p = M.get(name)
  if not p then return nil, "no project called '" .. tostring(name) .. "'" end
  local path = M.manifest_path(name)
  if not path then return nil, "a manifest needs a root to live in" end

  local skills = {}
  local okk, sk = pcall(require, "skills")
  if okk then
    for skname, owners in pairs(sk.project_keys()) do
      for _, o in ipairs(owners) do
        if o == name then skills[#skills + 1] = skname end
      end
    end
  end
  table.sort(skills)

  local doc = { name = name, roots = relative_roots(p.roots), skills = skills }
  sys.mkdir_p(path:gsub("/[^/]+$", ""))
  local f = io.open(path, "w")
  if not f then return nil, "cannot write " .. path end
  f:write(bog.json.encode(doc))
  f:close()
  bog.events.emit("project:manifest", { name = name, path = path, skills = #skills })
  return path, doc
end

function M.read_manifest(dir)
  local path = (dir and (M.abspath(dir) .. "/" .. M.MANIFEST)) or M.manifest_path()
  if not path then return nil end
  local data = bog.util.read_file(path)
  if not data then return nil end
  local ok, doc = pcall(bog.json.decode, data)
  return (ok and type(doc) == "table") and doc or nil
end

-- What this machine has, and what it lacks. Reports; never installs.
function M.reconcile(name)
  name = name or M.current()
  local doc = M.read_manifest()
  if not doc then return nil, "no manifest" end
  local have, missing = {}, {}
  local okk, sk = pcall(require, "skills")
  local known = {}
  if okk then
    -- every skill this machine has, keyed or not -- the question is existence,
    -- not availability in the current project
    for _, row in ipairs(sk.list()) do known[row.name] = true end
    for skname in pairs(sk.project_keys()) do known[skname] = true end
  end
  for _, want in ipairs(doc.skills or {}) do
    if known[want] then have[#have + 1] = want else missing[#missing + 1] = want end
  end
  return { name = doc.name or name, have = have, missing = missing }
end

function M.reconcile_report(name)
  local r, err = M.reconcile(name)
  if not r then return nil, err end
  if #r.missing == 0 then
    return string.format("%s: all %d skill(s) present", r.name, #r.have)
  end
  return string.format("%s expects %d skill(s) -- have %s; missing %s",
    r.name, #r.have + #r.missing,
    #r.have > 0 and table.concat(r.have, ", ") or "none",
    table.concat(r.missing, ", "))
end

-- ---------------------------------------------------------------------------
-- the global row exists from the first run
-- ---------------------------------------------------------------------------
function M.ensure_global()
  if not bog.db then return false end
  if not bog.store.project_get(M.GLOBAL) then
    bog.store.project_put(M.GLOBAL, { label = "loose chat", roots = {} })
    return true
  end
  return false
end

return M
