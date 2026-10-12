-- story/core.lua -- the `story` tool: a book's manuscript, cast, canon and style
-- for the model, the same way for every book.
--
-- ONE tool with `noun` + `action` and flat parameters (the tracker's shape).
-- Errors come back as "Error: ..." strings, never raised. The book defaults to
-- the current project's (if its root holds .boggart/story.json), else the cwd;
-- `book=` takes a project name or a path. Every read reindexes lazily first
-- (a stat per file), so answers are never stale.
--
--   book       init | get | list | reindex | check_layout
--   asset      list                        (kind=chapter|character|canon|outline|payoffs|other)
--   search     query                       (query=, kind=; file:line hits)
--   character  list | get                  (name=)
--   chapter    list | get | progress       (n=)
--   style      get | check | render        (n= or path= or text=; bits=)
--   plan       get | set | expand | edit      (lua/story/draft.lua: beats -> paragraph lines)
--   draft      next | write | redo | run      (one paragraph at a time, bounded context)
local sb = require("story.book")
local si = require("story.index")
local ss = require("story.style")
local json = require("json")
local M = {}

local function E(msg) return "Error: " .. msg end

local function book_of(a)
  local b, e = sb.resolve(a.book)
  if not b then return nil, e end
  si.fresh(b)
  return b
end

local function lines_of(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

local function chapter_row(book, n)
  n = tonumber(n)
  if not n then return nil, "chapter needs n=<number>" end
  for _, c in ipairs(si.chapters(book)) do if c.n == n then return c end end
  return nil, "no chapter " .. n .. " in " .. book.name
end

-- ---- book --------------------------------------------------------------------------------
local function book_init(a)
  local root = a.path or a.book or sys.cwd()
  if root:sub(1, 2) == "~/" then root = sys.home() .. root:sub(2) end
  root = root:gsub("/+$", "")
  if sys.stat(root) ~= "dir" then return E("no directory " .. root) end
  local mpath = root .. "/" .. sb.MANIFEST
  local proposal = sb.propose(root)
  local text = sb.pretty(proposal) .. "\n"
  if sys.stat(mpath) == "file" and not a.overwrite then
    return E(sb.MANIFEST .. " already exists in " .. root .. " (overwrite=true to replace it)")
  end
  if a.dry_run then return "Proposed " .. sb.MANIFEST .. " (not written):\n" .. text end
  if sys.stat(root .. "/.boggart") ~= "dir" then sys.mkdir_p(root .. "/.boggart") end
  local f, fe = io.open(mpath, "wb")
  if not f then return E(tostring(fe)) end
  f:write(text); f:close()
  local b = sb.load(root)
  local st = si.reindex(b, true)
  return string.format("Wrote %s\n%d chapters, %d characters, %d files indexed. Edit it to taste; "
    .. "`story book check_layout` shows what it matched.\n\n%s", mpath, st.chapters, st.characters, st.files, text)
end

local function totals(book)
  local words, done, n = 0, 0, 0
  for _, c in ipairs(si.chapters(book)) do
    words = words + (c.words or 0); n = n + 1
    if c.done == 1 then done = done + 1 end
  end
  return { chapters = n, done = done, words = words }
end
M.totals = totals

local function book_get(a)
  local b, e = book_of(a)
  if not b then return E(e) end
  local t = totals(b)
  local S, src = ss.load(b)
  local out = {
    "Book: " .. (b.m.title or b.name) .. "  (" .. b.name .. ")",
    "Root: " .. b.root,
    string.format("Chapters: %d (%d done)   Words: %d%s", t.chapters, t.done, t.words,
      b.m.target_words and (" / " .. b.m.target_words) or ""),
    "Characters: " .. #si.characters(b) .. "   Payoffs: " .. #si.payoffs(b),
    "Style: " .. tostring(src) .. (S.default_set and ("  (default set " .. S.default_set .. ")") or ""),
  }
  if #(b.m.povs or {}) > 0 then out[#out + 1] = "POVs: " .. table.concat(b.m.povs, ", ") end
  return table.concat(out, "\n")
end

local function book_list()
  local books = sb.list()
  if #books == 0 then return "No books yet. In a book's directory: story book init" end
  local out = {}
  for _, b in ipairs(books) do
    si.fresh(b)
    local t = totals(b)
    out[#out + 1] = string.format("%-24s %3d chapters %8d words  %s", b.name, t.chapters, t.words, b.root)
  end
  return table.concat(out, "\n")
end

local function book_reindex(a)
  local b, e = sb.resolve(a.book)
  if not b then return E(e) end
  local st = si.reindex(b, a.rebuild == true)
  return string.format("Indexed %s: %d files (%d changed, %d removed), %d chapters, %d characters, %d payoffs",
    b.name, st.files, st.changed, st.removed, st.chapters, st.characters, st.payoffs)
end

local function check_layout(a)
  local b, e = sb.resolve(a.book)
  if not b then return E(e) end
  local chapters, unnumbered = sb.chapters(b)
  local out = { "Manuscript (" .. table.concat(b.m.manuscript.glob, ", ") .. "):" }
  for _, c in ipairs(chapters) do
    local vs = {}
    for v in pairs(c.variants) do vs[#vs + 1] = (v == "" and "(base)" or v) end
    table.sort(vs)
    out[#out + 1] = string.format("  %s%3d  %s  [%s]%s", c.label and (c.label .. " ") or "", c.n, c.path,
      table.concat(vs, ", "), c.done and "  done" or "")
  end
  if #chapters == 0 then out[#out + 1] = "  (no chapters matched)" end
  if unnumbered and #unnumbered > 0 then
    out[#out + 1] = "Matched the glob but no chapter number (pattern " .. b.m.manuscript.number .. "):"
    for _, r in ipairs(unnumbered) do out[#out + 1] = "  " .. r end
  end
  local chars = sb.glob(b, b.m.characters)
  out[#out + 1] = "Characters: " .. #chars .. " file(s)"
  for _, c in ipairs(b.m.canon or {}) do
    out[#out + 1] = string.format("Canon %-8s %s: %d file(s)", c.role or "canon", c.glob or c.path or "?",
      #sb.glob(b, { c.glob or c.path }))
  end
  if b.m.payoffs then
    out[#out + 1] = "Payoffs: " .. b.m.payoffs .. (sys.stat(b.root .. "/" .. b.m.payoffs) == "file" and "" or "  (MISSING)")
  end
  local _, src = ss.load(b)
  out[#out + 1] = "Style: " .. tostring(src)
  return table.concat(out, "\n")
end

-- ---- asset ---------------------------------------------------------------------------------
local function asset_list(a)
  local b, e = book_of(a)
  if not b then return E(e) end
  local rows = si.files(b, (a.kind and a.kind ~= "" and a.kind ~= "all") and a.kind or nil)
  if #rows == 0 then return "No files" .. (a.kind and (" of kind " .. a.kind) or "") end
  local out, last = {}, nil
  for _, r in ipairs(rows) do
    if r.kind ~= last then out[#out + 1] = "## " .. r.kind; last = r.kind end
    out[#out + 1] = string.format("  %-48s %7d words  %s", r.path, r.words or 0, r.title or "")
  end
  return table.concat(out, "\n")
end

-- ---- search --------------------------------------------------------------------------------
-- FTS finds the files; the hits are then the LINES holding every term (stemmed
-- matching is FTS's job; the line filter is a plain case-insensitive prefix
-- match so "run" still finds "running").
local function search(a)
  local b, e = book_of(a)
  if not b then return E(e) end
  local query = a.query or a.text
  if not query or query == "" then return E("search needs query=") end
  local terms = {}
  for w in query:lower():gmatch("[%w']+") do terms[#terms + 1] = w end
  local files = si.search_files(b, query, a.kind)
  local limit = tonumber(a.limit) or 40
  local out, hits = {}, 0
  for _, f in ipairs(files) do
    local text = sb.read(b.root .. "/" .. f.path) or ""
    for i, line in ipairs(lines_of(text)) do
      local low, all = line:lower(), true
      for _, t in ipairs(terms) do
        if not low:find(t:sub(1, math.max(3, #t - 2)), 1, true) then all = false; break end
      end
      if all then
        hits = hits + 1
        if hits <= limit then
          local s = line:gsub("^%s+", "")
          if #s > 200 then s = s:sub(1, 197) .. "..." end
          out[#out + 1] = string.format("%s:%d: %s", f.path, i, s)
        end
      end
    end
  end
  if #files == 0 then return "No matches for '" .. query .. "'" end
  if hits == 0 then
    local names = {}
    for _, f in ipairs(files) do names[#names + 1] = f.path end
    return "The terms appear in these files, but never on one line:\n  " .. table.concat(names, "\n  ")
  end
  if hits > limit then out[#out + 1] = string.format("... %d more (limit=%d)", hits - limit, limit) end
  return table.concat(out, "\n")
end

-- ---- character ----------------------------------------------------------------------------
local function find_character(b, name)
  local want = tostring(name or ""):lower()
  if want == "" then return nil end
  for _, c in ipairs(si.characters(b)) do
    if c.id:lower() == want or c.id:lower():find(want, 1, true) then return c end
    for _, al in ipairs(json.decode(c.aliases or "[]")) do
      if al:lower() == want then return c end
    end
  end
  for _, c in ipairs(si.characters(b)) do
    if (c.title or ""):lower():find(want, 1, true) then return c end
  end
end

local function character_list(a)
  local b, e = book_of(a)
  if not b then return E(e) end
  local rows = si.characters(b)
  if #rows == 0 then return "No character sheets (manifest `characters`: " .. table.concat(b.m.characters, ", ") .. ")" end
  local out = {}
  for _, c in ipairs(rows) do
    local ms = si.mentions(b, c.id)
    local chs = {}
    for _, m in ipairs(ms) do chs[#chs + 1] = tostring(m.n) end
    out[#out + 1] = string.format("%-28s %s\n    aliases: %s\n    in chapters: %s", c.id, c.title or "",
      table.concat(json.decode(c.aliases or "[]"), ", "), #chs > 0 and table.concat(chs, " ") or "none")
  end
  return table.concat(out, "\n")
end

local function character_get(a)
  local b, e = book_of(a)
  if not b then return E(e) end
  local c = find_character(b, a.name)
  if not c then return E("no character matching '" .. tostring(a.name) .. "' (story character list)") end
  local text = sb.read(b.root .. "/" .. c.path) or ""
  local ms = si.mentions(b, c.id)
  local chs = {}
  for _, m in ipairs(ms) do chs[#chs + 1] = m.n .. "(" .. m.count .. ")" end
  return string.format("%s  [%s]\naliases: %s\nmentioned in chapter(count): %s\n\n%s", c.path, c.id,
    table.concat(json.decode(c.aliases or "[]"), ", "), #chs > 0 and table.concat(chs, " ") or "none", text)
end

-- ---- chapter ----------------------------------------------------------------------------------
local function chapter_list(a)
  local b, e = book_of(a)
  if not b then return E(e) end
  local rows = si.chapters(b)
  if #rows == 0 then return "No chapters matched " .. table.concat(b.m.manuscript.glob, ", ") .. " (story book check_layout)" end
  local out = {}
  for _, c in ipairs(rows) do
    out[#out + 1] = string.format("%s %3d  %-40s %6d words  %s", c.done == 1 and "✓" or "◐", c.n,
      c.title ~= "" and c.title or c.path, c.words or 0, c.path)
    if si.shrunk(c) then
      out[#out + 1] = string.format("      ! shorter than its %s variant (%d words) -- check nothing was lost",
        c.longest_variant == "" and "base" or c.longest_variant, c.longest)
    end
  end
  local t = totals(b)
  out[#out + 1] = string.format("%d chapters, %d done, %d words%s", t.chapters, t.done, t.words,
    b.m.target_words and (" of " .. b.m.target_words) or "")
  return table.concat(out, "\n")
end

local function chapter_get(a)
  local b, e = book_of(a)
  if not b then return E(e) end
  local c, ce = chapter_row(b, a.n)
  if not c then return E(ce) end
  local path = c.path
  if a.variant then
    local vs = json.decode(c.variants or "{}")
    path = vs[a.variant == "base" and "" or a.variant]
    if not path then return E("chapter " .. c.n .. " has no variant '" .. a.variant .. "'") end
  end
  local text = sb.read(b.root .. "/" .. path) or ""
  if a.raw ~= true then text = sb.drop_sections(text, b.m.drop_sections) end
  return string.format("[%s — %d words]\n%s", path, sb.word_count(text), text)
end

-- Plot status: the chapters against the outline and payoff ledger.
local function chapter_progress(a)
  local b, e = book_of(a)
  if not b then return E(e) end
  local t = totals(b)
  local out = { string.format("%s: %d chapters (%d done), %d words%s", b.m.title or b.name, t.chapters, t.done,
    t.words, b.m.target_words and string.format(" — %d%% of %d", math.floor(100 * t.words / b.m.target_words), b.m.target_words) or "") }
  for _, c in ipairs(si.chapters(b)) do
    out[#out + 1] = string.format("  %s %3d %6d words  %s", c.done == 1 and "✓ done " or "◐ draft", c.n, c.words or 0,
      c.title ~= "" and c.title or c.path)
  end
  local pay = si.payoffs(b)
  if #pay > 0 then
    out[#out + 1] = "Payoffs: " .. #pay .. " in " .. b.m.payoffs
    for _, p in ipairs(pay) do
      out[#out + 1] = string.format("  %2d. %s%s%s", p.n, p.title, p.carrier ~= "" and (" — carrier: " .. p.carrier) or "",
        p.span ~= "" and ("  [" .. p.span .. "]") or "")
    end
  end
  local outl = sb.glob(b, b.m.outline)
  if #outl > 0 then out[#out + 1] = "Outline: " .. table.concat(outl, ", ") end
  return table.concat(out, "\n")
end

-- ---- style: lua/story/stylecmd.lua ---------------------------------------------------------------
local stylecmd = require("story.stylecmd")

-- ---- plan + draft (lua/story/draft.lua) -----------------------------------------------------------
local sd = require("story.draft")

local function plan_book(a)
  local b, e = book_of(a)
  if not b then return nil, nil, e end
  local n = tonumber(a.n)
  if not n then return nil, nil, "needs n=<chapter number>" end
  return b, n
end

local function plan_get(a)
  local b, n, e = plan_book(a)
  if not b then return E(e) end
  local p = sd.load_plan(b, n)
  if not p then return E("no plan for chapter " .. n .. " (plan set n=" .. n .. " beats=\"...\")") end
  return sd.show(b, n, p)
end

-- A new plan from beats (one per line) plus card/title/pov/target, or a whole
-- plan file as text=. Refuses to replace a plan that has written paragraphs
-- unless overwrite=true (the plan is the only record of which lines are done).
local function plan_set(a)
  local b, n, e = plan_book(a)
  if not b then return E(e) end
  local old = sd.load_plan(b, n)
  if old and sd.progress(old).lines_done > 0 and a.overwrite ~= true then
    return E("chapter " .. n .. "'s plan has written paragraphs; overwrite=true to replace it (or plan edit / plan expand)")
  end
  local p
  if a.text and a.text:match("%S") then
    p = sd.parse(a.text)
  else
    p = old or sd.parse("")
    if a.beats then
      p.beats = {}
      for _, l in ipairs(sd.clean_lines(a.beats)) do p.beats[#p.beats + 1] = { text = l, lines = {}, notes = {} } end
    end
  end
  p.meta.chapter = tostring(n)
  for _, k in ipairs{ "title", "pov", "target", "narration", "unit" } do if a[k] then p.meta[k] = a[k] end end
  if a.set then p.meta.style = a.set end
  if a.append ~= nil then p.meta.append = a.append == true and "true" or nil end
  if a.card then
    local kept = {}
    for _, l in ipairs(p.preamble) do if not l:match("^%s*Card:") then kept[#kept + 1] = l end end
    table.insert(kept, 1, "Card: " .. a.card)
    p.preamble = kept
  end
  if #p.beats == 0 then return E("a plan needs beats= (one per line) or text=") end
  local target = sd.target_of(b, n, p)
  if not p.meta.target then p.meta.target = target end
  local ok, we = sd.save_plan(b, n, p)
  if not ok then return E(tostring(we)) end
  local warn = ""
  if sys.stat(b.root .. "/" .. target) == "file" and p.meta.append ~= "true" and not p.meta.started then
    warn = "\nNote: " .. target .. " already exists; drafting will refuse to add to it unless append=true."
  end
  return "Saved " .. sd.plan_path(b, n):sub(#b.root + 2) .. warn .. "\n\n" .. sd.show(b, n, sd.load_plan(b, n))
end

local function with_plan(a, fn)
  local b, n, e = plan_book(a)
  if not b then return E(e) end
  local p = sd.load_plan(b, n)
  if not p then return E("no plan for chapter " .. n .. " (plan set)") end
  local out, err = fn(b, n, p)
  if not out then return E(tostring(err)) end
  return out
end

local function plan_expand(a)
  return with_plan(a, function(b, n, p)
    local id = a.id or (sd.next_task(p).beat or {}).id
    return sd.expand(b, n, p, id, a.lines or a.text or "")
  end)
end

local function plan_edit(a)
  return with_plan(a, function(b, n, p)
    local id = tostring(a.id or "")
    for _, bt in ipairs(p.beats) do
      if bt.id == id then bt.text = a.text or bt.text; sd.save_plan(b, n, p); return "Beat " .. id .. " updated." end
      for _, l in ipairs(bt.lines) do
        if l.id == id then
          if a.text then l.text = a.text end
          if a.done ~= nil then l.done = a.done == true end
          sd.save_plan(b, n, p)
          return "Line " .. id .. " updated."
        end
      end
    end
    return nil, "no beat or line " .. id
  end)
end

local function draft_next(a)
  return with_plan(a, function(b, n, p)
    local task = sd.next_task(p)
    if task.kind == "done" then return "Chapter " .. n .. "'s plan is fully written." end
    if task.kind == "empty" then return nil, "the plan has no beats" end
    local text, report = sd.packet(b, n, p, task, { budget = a.budget })
    local how = task.kind == "outline"
      and ("When done: story plan expand n=" .. n .. " id=" .. task.beat.id .. " lines=\"...\"")
      or ("When done: story draft write n=" .. n .. " id=" .. task.line.id .. " text=\"...\"")
    return text .. "\n\n---\n" .. how .. "\n(packet: " .. table.concat(report, ", ") .. ")"
  end)
end

local function draft_write(a)
  return with_plan(a, function(b, n, p) return sd.write(b, n, p, a.id, a.text, { force = a.force == true }) end)
end

local function draft_redo(a)
  return with_plan(a, function(b, n, p) return sd.redo(b, n, p, a.text, { author = a._author }) end)
end

local function draft_candidates(a)
  local b, n, e = plan_book(a)
  if not b then return E(e) end
  local out, err = sd.candidates(b, n, a.k or a.candidates or 3, { model = a.model, budget = a.budget, judge = a.judge == true })
  return out or E(tostring(err))
end

local function draft_pick(a)
  local b, n, e = plan_book(a)
  if not b then return E(e) end
  local out, err = sd.pick(b, n, a.c or a.pick, { author = a._author })
  return out or E(tostring(err))
end

local function draft_run(a)
  local b, n, e = plan_book(a)
  if not b then return E(e) end
  local out, err = sd.run(b, n, a.steps or 1, { model = a.model, budget = a.budget, candidates = a.candidates,
    judge = a.judge == true })
  if not out then return E(tostring(err)) end
  local p = sd.load_plan(b, n)
  local pr = p and sd.progress(p)
  return out .. (pr and string.format("\nPlan: beats %d/%d, paragraphs %d/%d.", pr.beats_done, pr.beats, pr.lines_done, pr.lines) or "")
end

-- ---- dispatch -----------------------------------------------------------------------------------
M.ACTIONS = {
  book = { init = book_init, get = book_get, list = book_list, reindex = book_reindex, check_layout = check_layout },
  asset = { list = asset_list },
  search = { query = search },
  character = { list = character_list, get = character_get },
  chapter = { list = chapter_list, get = chapter_get, progress = chapter_progress },
  style = stylecmd.ACTIONS,
  plan = { get = plan_get, set = plan_set, expand = plan_expand, edit = plan_edit },
  draft = { next = draft_next, write = draft_write, redo = draft_redo, run = draft_run,
            candidates = draft_candidates, pick = draft_pick },
}
local DEFAULT = { search = "query", asset = "list" }
-- the story model's nouns (entity, event, fact, knows, promise, ...)
local sw = require("story.world")
for noun, acts in pairs(sw.ACTIONS) do M.ACTIONS[noun] = acts end
for noun, act in pairs(sw.DEFAULT) do DEFAULT[noun] = act end
-- the world lookups (geo, check): code-only questions about where things are
local sg = require("story.geotool")
for noun, acts in pairs(sg.ACTIONS) do M.ACTIONS[noun] = acts end
for noun, act in pairs(sg.DEFAULT) do DEFAULT[noun] = act end

function M.call(a)
  a = a or {}
  local noun = a.noun
  local acts = M.ACTIONS[noun or ""]
  if not acts then
    local ns = {}
    for k in pairs(M.ACTIONS) do ns[#ns + 1] = k end
    table.sort(ns)
    return E("unknown noun '" .. tostring(noun) .. "' (" .. table.concat(ns, "|") .. ")")
  end
  local action = a.action or DEFAULT[noun]
  local fn = acts[action or ""]
  if not fn then
    local as = {}
    for k in pairs(acts) do as[#as + 1] = k end
    table.sort(as)
    return E(noun .. " has no action '" .. tostring(action) .. "' (" .. table.concat(as, "|") .. ")")
  end
  if not (bog and bog.db) then return E("store not open") end
  local ok, out = pcall(fn, a)
  if not ok then return E(tostring(out)) end
  return out
end

M.tool = {
  description = "The book you are writing: manuscript chapters, character sheets, canon docs, payoffs and the "
    .. "book's own prose style rules, for any book with a .boggart/story.json (book= a project name or path; "
    .. "default the current project). One tool: pick a `noun` and an `action`. "
    .. "book init|get|list|reindex|check_layout; asset list (kind=); search query (query=, kind=; returns file:line); "
    .. "character list|get (name= id or alias); chapter list|get|progress (n=); "
    .. "style get (set=, pov=, bits=)|check (n=|path=|text=, set=)|render|sets|exemplars (op=list|add|harvest)|"
    .. "baseline (op=build|show)|drift|slop|ban (phrase=)|decode|prefs|dataset|finetune. "
    .. "Style lives in the book: a voice card, the author's own exemplar passages, and rules the checker enforces "
    .. "(never put in prompts); named sets (e.g. first-past, third-past) switch person/tense per book, POV or chapter. "
    .. "search before asserting a canon fact. "
    .. "DRAFTING is by expansion, never one big pass: plan set n= beats= (one line per beat; card=, title=, pov=, target=); "
    .. "plan get|expand (id= beat, lines= one line per paragraph)|edit (id=, text=, done=); "
    .. "draft next n= (the bounded context packet for the next step: outline a beat or write one paragraph) "
    .. "then draft write n= id= text= (appends ONE paragraph, measures words on disk, style-checks, checkpoints) "
    .. "or draft redo n= text= (replace the last step); draft run n= steps= [candidates=3] (fresh model calls); "
    .. "draft candidates n= k=3 then draft pick n= c=N (the author's pick is logged as a preference).",
  input_schema = {
    type = "object",
    properties = {
      noun = { type = "string", description = "book|asset|search|character|chapter|style" },
      action = { type = "string", description = "verb within the noun (see description)" },
      book = { type = "string", description = "book project name or path (default: current project / cwd)" },
      n = { type = "integer", description = "chapter number" },
      name = { type = "string", description = "character id or alias" },
      query = { type = "string", description = "search words (all must appear)" },
      kind = { type = "string", description = "chapter|character|canon|outline|payoffs|other|all" },
      path = { type = "string", description = "a file (relative to the book root) for style check/render, or a dir for book init" },
      text = { type = "string", description = "prose to style-check directly" },
      bits = { type = "string", description = "style bit names, comma separated (default: the book's order)" },
      pov = { type = "string" },
      variant = { type = "string", description = "chapter get: a variant other than the preferred (base for none)" },
      raw = { type = "boolean", description = "chapter get: keep the dropped meta sections" },
      rebuild = { type = "boolean" }, overwrite = { type = "boolean" }, dry_run = { type = "boolean" },
      id = { type = "string", description = "plan beat id (3) or paragraph line id (3.2)" },
      beats = { type = "string", description = "plan set: beats, one per line" },
      lines = { type = "string", description = "plan expand: paragraph lines, one per line" },
      card = { type = "string" }, title = { type = "string" }, target = { type = "string" },
      narration = { type = "string", description = "plan set: e.g. \"close third person, past tense\" (default: the manifest's)" },
      append = { type = "boolean", description = "plan set: let drafting add to an existing chapter file" },
      done = { type = "boolean" }, force = { type = "boolean" },
      steps = { type = "integer", description = "draft run: how many steps" },
      model = { type = "string", description = "draft run: model or preset for the steps" },
      budget = { type = "integer", description = "packet size in characters (default 24000)" },
      set = { type = "string", description = "style set (e.g. first-past, third-past, or the book's own)" },
      unit = { type = "string", description = "plan set: beat (default) or line -- how much one draft call writes" },
      op = { type = "string", description = "style exemplars list|add|harvest; style baseline show|build" },
      phrase = { type = "string" }, level = { type = "string", description = "suggestion|warning|error" },
      paths = { type = "string", description = "comma-separated files (baseline/dataset from these)" },
      golden = { type = "boolean" }, mode = { type = "string" }, lines = { type = "string" },
      candidates = { type = "integer", description = "draft run/candidates: versions to generate and rank" },
      k = { type = "integer" }, c = { type = "integer", description = "draft pick: candidate number" },
      judge = { type = "boolean", description = "rank candidates with an editor-style judge too" },
      iters = { type = "integer" }, base = { type = "string" }, run = { type = "boolean" },
      limit = { type = "integer" },
    },
    required = { "noun" },
  },
  -- the model is never the author: whatever it passes, its writes are proposals
  run = function(a) a = a or {}; a._author = nil; return M.call(a) end,
}
M.tool.description = M.tool.description .. " " .. sw.DESCRIPTION .. " " .. sg.DESCRIPTION
for k, v in pairs(sw.PROPS) do
  if not M.tool.input_schema.properties[k] then M.tool.input_schema.properties[k] = v end
end
for k, v in pairs(sg.PROPS) do
  if not M.tool.input_schema.properties[k] then M.tool.input_schema.properties[k] = v end
end
M.tool.input_schema.properties.noun.description = "book|asset|search|character|chapter|style|plan|draft|"
  .. "entity|event|fact|knows|promise|exemption|proposal|lore|model|geo|check"

function M.register()
  if bog and bog.tools and bog.tools.register then bog.tools.register("story", M.tool) end
end

return M
