-- story/book.lua -- what a book IS to boggart: its manifest, where it lives, and
-- which of its files are chapters, character sheets and canon.
--
-- A book declares itself with <root>/.boggart/story.json, committed with the
-- book (next to .boggart/project.json). Everything is globs and explicit lists,
-- so a book keeps whatever layout it grew -- ~/novel's structured folders and
-- story-writing's flat, number-prefixed docs alike -- without reorganising.
-- The manuscript is the source of truth; boggart only ever indexes it.
--
--   { "title": "...", "layout": "structured|flat",
--     "manuscript": { "glob": ["chapters/*.md"], "number": "^(%d+)",
--                     "prefer": ["revised", ""], "exclude": ["*_recovered.md"],
--                     "named": { "prologue": 0 }, "done": ["revised"],
--                     "alternates": ["slowcut_draft"] },
--     "characters": ["characters/*.md"],
--     "canon": [ { "glob": "plot/*.md", "role": "plot" }, ... ],
--     "payoffs": "plot/payoffs.md", "outline": ["plot/act_*.md"],
--     "style": ".boggart/style.lua", "povs": ["vera"],
--     "drop_sections": ["Canon flags", "Tension map"], "target_words": 110000,
--     "narration": "close third person, past tense" }
--
-- Chapter files: `number` (a Lua pattern with one capture, applied to the file
-- name without .md) yields the chapter number -- or a name looked up in
-- `named` ("prologue" -> 0). What FOLLOWS the match is the variant ("07_revised"
-- -> "revised", "chapter01_slowcut_draft" -> "slowcut_draft"); `prefer` picks
-- which variant is THE chapter, and `done` says which variants count as done.
-- `alternates` are other CUTS, not revisions: a preferred variant shorter than
-- a revision is flagged (a lost revision), shorter than an alternate is not.
local M = {}

M.MANIFEST = ".boggart/story.json"
M.SKIP_DIRS = { [".git"] = true, [".boggart"] = true, [".story"] = true, build = true,
                node_modules = true, [".venv"] = true, dist = true }

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end
M.read = read

local function as_list(v)
  if v == nil then return {} end
  if type(v) == "string" then return { v } end
  return v
end
M.as_list = as_list

-- ---- manifests ----------------------------------------------------------------
M.DEFAULTS = {
  layout = "structured",
  manuscript = { glob = { "chapters/*.md" }, number = "^(%d+)", prefer = { "revised", "" },
                 exclude = {}, named = {}, done = { "revised" } },
  characters = { "characters/*.md" },
  canon = {},
  outline = {},
  style = ".boggart/style.lua",
  povs = {},
  drop_sections = {},
}

local function merge(defaults, m)
  local out = {}
  for k, v in pairs(defaults) do out[k] = v end
  for k, v in pairs(m or {}) do
    if type(v) == "table" and type(defaults[k]) == "table" and defaults[k][1] == nil and next(defaults[k]) ~= nil then
      out[k] = merge(defaults[k], v)
    else
      out[k] = v
    end
  end
  return out
end

-- -> book { name, root, m (manifest, defaults merged), raw } | nil, err
function M.load(root, name)
  root = tostring(root):gsub("/+$", "")
  local text = read(root .. "/" .. M.MANIFEST)
  if not text then return nil, "no " .. M.MANIFEST .. " in " .. root .. " (story book init)" end
  local ok, raw = pcall(require("json").decode, text)
  if not ok or type(raw) ~= "table" then return nil, root .. "/" .. M.MANIFEST .. " is not valid JSON" end
  local m = merge(M.DEFAULTS, raw)
  m.manuscript.glob = as_list(m.manuscript.glob)
  m.manuscript.exclude = as_list(m.manuscript.exclude)
  m.manuscript.prefer = as_list(m.manuscript.prefer)
  m.characters = as_list(m.characters)
  m.outline = as_list(m.outline)
  return { name = name or M.name_for(root), root = root, m = m, raw = raw }
end

-- The name a book goes by: the boggart project whose root it is, else its
-- directory's basename.
function M.name_for(root)
  local okp, proj = pcall(require, "project")
  if okp and proj.list then
    for _, p in ipairs(proj.list()) do
      for _, r in ipairs(p.roots or {}) do
        if r == root then return p.name end
      end
    end
  end
  return root:match("([^/]+)$") or root
end

-- Which book does a call mean? `spec` is a path, a book/project name, or nil:
-- nil means the current project's root if it has a manifest, else the cwd.
function M.resolve(spec)
  local okp, proj = pcall(require, "project")
  local function try_root(root, name)
    if root and sys.stat(root .. "/" .. M.MANIFEST) == "file" then return M.load(root, name) end
  end
  if spec and spec ~= "" then
    if spec:find("/", 1, true) or spec == "." then
      local root = spec
      if spec == "." then root = sys.cwd() end
      if root:sub(1, 2) == "~/" then root = sys.home() .. root:sub(2) end
      local b, e = try_root(root)
      if b or e then return b, e end
      return nil, "no " .. M.MANIFEST .. " in " .. root .. " (story book init)"
    end
    if okp and proj.get then
      local p = proj.get(spec)
      if p then
        for _, r in ipairs(p.roots or {}) do
          local b = try_root(r, p.name)
          if b then return b end
        end
        return nil, "project '" .. spec .. "' has no " .. M.MANIFEST .. " in its roots (story book init)"
      end
    end
    return nil, "no book called '" .. spec .. "'"
  end
  if okp and proj.current and proj.get then
    local p = proj.get(proj.current())
    if p then
      for _, r in ipairs(p.roots or {}) do
        local b = try_root(r, p.name)
        if b then return b end
      end
    end
  end
  local b = try_root(sys.cwd())
  if b then return b end
  return nil, "no book here: open a book's project, pass book=<name or path>, or run story book init"
end

-- Every book boggart knows: projects whose roots hold a manifest.
function M.list()
  local out = {}
  local okp, proj = pcall(require, "project")
  if not (okp and proj.list) then return out end
  for _, p in ipairs(proj.list()) do
    for _, r in ipairs(p.roots or {}) do
      if sys.stat(r .. "/" .. M.MANIFEST) == "file" then
        local b = M.load(r, p.name)
        if b then out[#out + 1] = b end
        break
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- ---- globs -------------------------------------------------------------------------
-- A glob as a Lua pattern over a relative path ("*" stays within a directory).
local function glob_pat(g)
  local p = g:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", "[^/]*"):gsub("%?", "[^/]")
  return "^" .. p .. "$"
end
M.glob_pat = glob_pat

local function excluded(rel, excludes)
  local base = rel:match("([^/]+)$")
  for _, x in ipairs(excludes or {}) do
    local p = glob_pat(x)
    if rel:match(p) or base:match(p) then return true end
  end
  return false
end

-- Relative paths matching any of `globs`, minus `excludes`, sorted, de-duplicated.
function M.glob(book, globs, excludes)
  local out, seen = {}, {}
  for _, g in ipairs(as_list(globs)) do
    for _, full in ipairs(sys.glob(book.root .. "/" .. g) or {}) do
      local rel = full:sub(#book.root + 2)
      if not seen[rel] and sys.stat(full) == "file" and not excluded(rel, excludes) then
        seen[rel] = true
        out[#out + 1] = rel
      end
    end
  end
  table.sort(out)
  return out
end

-- Every markdown file under the book (what search and the asset list see),
-- skipping VCS, build and boggart's own dirs.
function M.all_markdown(book)
  local out = {}
  local function walk(dir, rel)
    local items = sys.listdir(dir) or {}
    table.sort(items)
    for _, name in ipairs(items) do
      local full, r = dir .. "/" .. name, (rel == "" and name or (rel .. "/" .. name))
      local k = sys.stat(full)
      if k == "dir" then
        if not M.SKIP_DIRS[name] then walk(full, r) end
      elseif k == "file" and name:match("%.md$") then
        out[#out + 1] = r
      end
    end
  end
  walk(book.root, "")
  return out
end

-- ---- chapters ------------------------------------------------------------------------
-- -> list of { n, ord, label, path (the chosen variant), variant, variants = {name = path}, done }
function M.chapters(book)
  local ms = book.m.manuscript
  local by_n, order = {}, {}
  local unnumbered = {}
  for _, rel in ipairs(M.glob(book, ms.glob, ms.exclude)) do
    local base = (rel:match("([^/]+)$") or rel):gsub("%.md$", "")
    local s, e, cap = base:find(ms.number)
    local n
    if cap then n = tonumber(cap) or (ms.named and ms.named[cap:lower()]) end
    if n then
      local variant = base:sub(e + 1):gsub("^[_%-%.%s]+", ""):gsub("[_%-%.%s]+$", "")
      local c = by_n[n]
      if not c then
        c = { n = n, ord = n * 10, label = (not tonumber(cap)) and cap or nil, variants = {} }
        by_n[n] = c
        order[#order + 1] = n
      end
      c.variants[variant] = rel
    else
      unnumbered[#unnumbered + 1] = rel
    end
  end
  table.sort(order)
  local done = {}
  for _, d in ipairs(as_list(ms.done)) do done[d] = true end
  local out = {}
  for _, n in ipairs(order) do
    local c = by_n[n]
    for _, v in ipairs(ms.prefer) do
      if c.variants[v] then c.variant, c.path = v, c.variants[v]; break end
    end
    if not c.path then
      local names = {}
      for v in pairs(c.variants) do names[#names + 1] = v end
      table.sort(names)
      c.variant, c.path = names[1], c.variants[names[1]]
    end
    c.done = done[c.variant] == true
    out[#out + 1] = c
  end
  return out, unnumbered
end

-- The body of a chapter as the reader sees it: drop_sections cut (a "## Canon
-- flags" heading and everything after it, as book.json's EPUB build does).
function M.drop_sections(text, sections)
  if not sections or #sections == 0 then return text end
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local h = line:match("^%s*#+%s*(.-)%s*$")
    if h then
      local stop = false
      for _, s in ipairs(sections) do
        if h:lower():find(s:lower(), 1, true) == 1 then stop = true end
      end
      if stop then break end
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

-- Words of prose: heading lines and horizontal rules are not the story.
function M.word_count(text)
  local n = 0
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if not line:match("^%s*#") and not line:match("^%s*[%-%*_][%-%*_%s]*$") then
      for _ in line:gmatch("%S+") do n = n + 1 end
    end
  end
  return n
end

-- ---- proposing a manifest (story book init) ---------------------------------------------
-- A first manifest for `root`, from what is on disk. It is a PROPOSAL: written
-- once, then the author edits it. Reads ~/novel-style book.json (prefer,
-- drop_sections) rather than copying its job.
function M.propose(root)
  root = tostring(root):gsub("/+$", "")
  local fake = { root = root, m = M.DEFAULTS }
  local m = { title = root:match("([^/]+)$") }
  local bj = read(root .. "/book.json")
  if bj then
    local okj, b = pcall(require("json").decode, bj)
    if okj and type(b) == "table" then
      m.title = b.title or m.title
      m.drop_sections = b.drop_sections
      if b.chapters_dir then
        m.manuscript = { glob = { b.chapters_dir .. "/*.md" }, number = "^(%d+)",
                         prefer = b.prefer or { "revised", "" }, done = { "revised" } }
      end
    end
  end
  local has_dir = function(d) return sys.stat(root .. "/" .. d) == "dir" end
  if has_dir("chapters") then
    m.layout = "structured"
    m.manuscript = m.manuscript or { glob = { "chapters/*.md" }, number = "^(%d+)",
                                     prefer = { "revised", "" }, done = { "revised" } }
    m.manuscript.exclude = { "*_recovered.md" }
    m.characters = has_dir("characters") and { "characters/*.md" } or {}
    m.canon = {}
    if has_dir("plot") then m.canon[#m.canon + 1] = { glob = "plot/*.md", role = "plot" } end
    if has_dir("research") then m.canon[#m.canon + 1] = { glob = "research/*.md", role = "lore" } end
    if sys.stat(root .. "/plot/payoffs.md") == "file" then m.payoffs = "plot/payoffs.md" end
    local acts = M.glob(fake, { "plot/act_*.md" })
    if #acts > 0 then m.outline = { "plot/act_*.md" } end
  else
    m.layout = "flat"
    local ms = M.glob(fake, { "manuscript_*.md" })
    if #ms > 0 then
      local first = ms[1]
      if first:match("chapter%d+") then
        m.manuscript = { glob = { "manuscript_*.md" }, number = "chapter(%d+)", prefer = { "draft" },
                         exclude = {}, done = {} }
      else
        m.manuscript = { glob = { "manuscript_*.md" }, number = "^manuscript_(%a+)",
                         named = { prologue = 0, epilogue = 999 }, prefer = { "draft" }, exclude = {}, done = {} }
      end
    else
      m.manuscript = { glob = { "chapters/*.md" }, number = "^(%d+)", prefer = { "" }, exclude = {}, done = {} }
    end
    -- numbered docs are the flat layout's canon; the author sorts characters
    -- from lore by editing the proposal (a flat book's names do not say)
    m.characters = {}
    m.canon = { { glob = "[0-9]*.md", role = "lore" } }
  end
  m.style = ".boggart/style.lua"
  m.povs = {}
  return m
end

-- Canonical-enough JSON for a hand-edited file: two-space indent, stable keys.
function M.pretty(v, indent)
  indent = indent or ""
  local json = require("json")
  if type(v) ~= "table" then return json.encode(v) end
  local is_arr = #v > 0 or next(v) == nil
  local inner = indent .. "  "
  if is_arr then
    if #v == 0 then return "[]" end
    local simple = true
    for _, x in ipairs(v) do if type(x) == "table" then simple = false end end
    if simple then
      local parts = {}
      for _, x in ipairs(v) do parts[#parts + 1] = json.encode(x) end
      return "[" .. table.concat(parts, ", ") .. "]"
    end
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = inner .. M.pretty(x, inner) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = inner .. json.encode(k) .. ": " .. M.pretty(v[k], inner) end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

return M
