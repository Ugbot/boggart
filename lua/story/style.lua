-- story/style.lua -- a book's style, in layers, with named SETS
-- (docs/story-style.md).
--
-- What the research said, and what this does about it:
--   * long rule lists in a drafting prompt are mostly dropped (and naming banned
--     words can prime them) -> rules never go into the drafting prompt; they
--     are the CHECKER's (story/lint.lua);
--   * the author's own prose beats any description of it -> EXEMPLARS are the
--     main drafting signal, chosen per POV and mode;
--   * a voice description should be short and grounded in those exemplars ->
--     the VOICE CARD is a handful of lines;
--   * style belongs to the book -> everything here is the book's, and a
--     library set is only ever used by an explicit `extends`.
--
-- <book>/.boggart/style.lua is DATA (loaded with no environment):
--
--   return {
--     narration = "close third person, past tense",  -- default narration line
--     voice = { "The book is a man filling forms at the end of an empire.", ... },
--     pov = { vera = "time-stamped, procedural; files her feelings", ... },
--     exemplars = { { id = "viktor-archive", pov = "viktor", mode = "interior", golden = true, text = [[...]] } },
--     pairs = { { before = "...", after = "...", note = "..." } },  -- before/after edits
--     rules = { { id = "Book.Banned", type = "existence", level = "error", tokens = {...} }, ... },
--     allow = { "Book.OpenerRun" },            -- deliberate devices: findings become notes
--     decode = { min_p = 0.03, dry_multiplier = 0.8 },  -- local-model sampler settings
--     slop = { off = { "Slop.EmDash" } },      -- the built-in slop pack, tuned
--     default_set = "third-past",
--     pov_sets = { moth = "moth-first" },      -- a POV narrated in its own set
--     sets = {                                 -- named variations of all the above
--       ["moth-first"] = { extends = "first-past", voice = { "..." }, exemplar_set = "moth" },
--     },
--     guide = { order = {...}, bits = {...} }, -- the long guide: reference for revision
--     limits = { max_words = 80 },             -- numbers the guide's {{placeholders}} use
--   }
--
-- More exemplars can live as files: <book>/.boggart/style/exemplars/*.md, each
-- starting with `key: value` lines (pov, mode, set, golden) then a blank line.
-- The older flat format (limits/banned/tells/similes/refrains/openers/advisory/
-- bits/order at the top) still loads: it is converted to rules on the way in.
local lint = require("story.lint")
local M = {}

M.META_SECTIONS = { "Tension map", "Canon flags", "Style audit", "Meta" }

function M.path(book) return book.root .. "/" .. (book.m.style or ".boggart/style.lua") end

local function read(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

-- data only: no globals at all
local function load_data(p)
  local src = read(p)
  if not src then return nil, "no style file at " .. p end
  local chunk, err = load(src, "@" .. p, "t", {})
  if not chunk then return nil, "style file does not parse: " .. tostring(err) end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= "table" then return nil, "style file did not return a table" end
  return t
end
M.load_data = load_data

-- ---- the older flat format -> rules -------------------------------------------------------------
local THE_WAY_IDIOMS = { "on the way", "in the way", "by the way", "out of the way", "the way out",
                         "the way back", "the way home", "the way in" }
local ADVISORY_IDS = { chains = { "Book.AndChain", "Book.WasChain" }, same_opener = { "Book.OpenerRun" },
  avg_min = { "Book.AvgMin" }, max_words = { "Book.SentenceMax" }, avg = { "Book.AvgMax" },
  the_way = { "Book.TheWay" }, banned = { "Book.Banned" }, tells = { "Book.Tells" },
  similes = { "Book.SimileLine", "Book.SimileDensity" }, refrains = { "Book.Refrain" }, openers = { "Book.MediaOpener" } }

function M.legacy_rules(t)
  local soft = {}
  for _, k in ipairs(t.advisory or {}) do for _, id in ipairs(ADVISORY_IDS[k] or {}) do soft[id] = true end end
  local function lvl(id) return soft[id] and "warning" or "error" end
  local L, out = t.limits or {}, {}
  if t.banned and #t.banned > 0 then
    out[#out + 1] = { id = "Book.Banned", type = "existence", level = lvl("Book.Banned"), tokens = t.banned,
                      message = "'{token}' is banned in this book" }
  end
  if t.tells and #t.tells > 0 then
    out[#out + 1] = { id = "Book.Tells", type = "existence", level = lvl("Book.Tells"), tokens = t.tells,
                      message = "theme tell: '{token}'" }
  end
  if L.max_words then
    out[#out + 1] = { id = "Book.SentenceMax", type = "metric", metric = "sentence_max", max = L.max_words, level = lvl("Book.SentenceMax") }
  end
  if L.avg_max then
    out[#out + 1] = { id = "Book.AvgMax", type = "metric", metric = "avg_sentence", max = L.avg_max, level = lvl("Book.AvgMax"),
                      message = "average sentence {n} words (ceiling {max})" }
  end
  if L.avg_min then
    out[#out + 1] = { id = "Book.AvgMin", type = "metric", metric = "avg_sentence", min = L.avg_min, level = lvl("Book.AvgMin"),
                      message = "average sentence {n} words (below {min})" }
  end
  if L.the_way_budget then
    out[#out + 1] = { id = "Book.TheWay", type = "occurrence", scope = "text", tokens = { "the way" }, exceptions = THE_WAY_IDIOMS,
                      max = L.the_way_budget, level = lvl("Book.TheWay"), message = "'the way' {n} times (budget {max}; lines {lines})" }
  end
  if L.same_opener_run then
    out[#out + 1] = { id = "Book.OpenerRun", type = "repetition", what = "opener", run = L.same_opener_run, level = lvl("Book.OpenerRun") }
  end
  if t.chains then
    out[#out + 1] = { id = "Book.AndChain", type = "existence", tokens = { "~, and [^,]+, and" }, level = lvl("Book.AndChain"),
                      message = "a rolling ', and ..., and' chain" }
    out[#out + 1] = { id = "Book.WasChain", type = "existence", tokens = { "~ was [^,]+, and [^,]+ was" }, level = lvl("Book.WasChain"),
                      message = "a 'was ..., and ... was' aphorism chain" }
  end
  if t.similes then
    out[#out + 1] = { id = "Book.SimileLine", type = "metric", metric = "similes_per_line", max = t.similes.per_line or 1, level = lvl("Book.SimileLine") }
    if t.similes.per_words then
      out[#out + 1] = { id = "Book.SimileDensity", type = "metric", metric = "simile_density", per_words = t.similes.per_words, level = lvl("Book.SimileDensity") }
    end
  end
  if t.refrains and t.refrains.list then
    for _, r in ipairs(t.refrains.list) do
      out[#out + 1] = { id = "Book.Refrain", type = "occurrence", scope = "text", tokens = { r }, max = t.refrains.max or 2,
                        level = lvl("Book.Refrain"), message = "refrain '" .. r .. "' used {n} times (max {max})" }
    end
  end
  if t.openers then
    out[#out + 1] = { id = "Book.MediaOpener", type = "metric", metric = "media_opener", level = lvl("Book.MediaOpener") }
  end
  return out
end

-- ---- loading --------------------------------------------------------------------------------------
-- -> S (always a table) and where it came from / why it is empty
function M.load(book)
  local p = M.path(book)
  local t, err = load_data(p)
  local S = { book = book, source = t and p or err, data = t or {} }
  t = t or {}
  local base = {
    narration = t.narration or book.m.narration,
    voice = t.voice or {}, pov = t.pov or {}, exemplars = t.exemplars or {}, pairs = t.pairs or {},
    rules = t.rules or M.legacy_rules(t), allow = t.allow or {}, decode = t.decode or {}, slop = t.slop,
  }
  -- a legacy file's "advisory" devices were the author saying "this is voice"
  S.base = base
  S.sets = t.sets or {}
  S.default_set = t.default_set
  S.pov_sets = t.pov_sets or {}
  S.guide = t.guide or { bits = t.bits, order = t.order }
  S.limits = t.limits or {}
  S.dir_exemplars = M.load_exemplar_files(book)
  return S, S.source
end

-- <book>/.boggart/style/exemplars/*.md
function M.load_exemplar_files(book)
  local out = {}
  local dir = book.root .. "/.boggart/style/exemplars"
  for _, full in ipairs(sys.glob(dir .. "/*.md") or {}) do
    local text = read(full) or ""
    local meta, body = {}, text
    local lines, i = {}, 1
    for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
    if lines[1] == "---" then
      i = 2
      while lines[i] and lines[i] ~= "---" do
        local k, v = lines[i]:match("^([%w_]+):%s*(.-)%s*$")
        if k then meta[k] = v end
        i = i + 1
      end
      i = i + 1
    else
      while lines[i] and lines[i]:match("^[%w_]+:%s") do
        local k, v = lines[i]:match("^([%w_]+):%s*(.-)%s*$")
        meta[k] = v
        i = i + 1
      end
    end
    body = table.concat(lines, "\n", i):gsub("^%s+", ""):gsub("%s+$", "")
    if body ~= "" then
      out[#out + 1] = { id = full:match("([^/]+)%.md$"), pov = meta.pov, mode = meta.mode, set = meta.set,
                        golden = meta.golden == "true", text = body, file = full }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- ---- sets ---------------------------------------------------------------------------------------
local function find_set(S, name)
  if S.sets[name] then return S.sets[name], "book" end
  for _, p in ipairs{ S.book.root .. "/.boggart/style/sets/" .. name .. ".lua",
                      ((os.getenv("BOGGART_HOME") or ((os.getenv("HOME") or "") .. "/.boggart")) .. "/style/sets/" .. name .. ".lua") } do
    local t = load_data(p)
    if t then return t, p end
  end
  local lib = require("story.sets")[name]
  if lib then return lib, "built-in" end
end

-- The chain for a set, root first: { {name, data, from}, ... }
function M.chain(S, name)
  local chain, seen = {}, {}
  local n = name
  while n and not seen[n] do
    seen[n] = true
    local d, from = find_set(S, n)
    if not d then return nil, "no style set '" .. n .. "' (book sets, .boggart/style/sets/, ~/.boggart/style/sets/, built-in: "
      .. table.concat(M.builtin_names(), ", ") .. ")" end
    table.insert(chain, 1, { name = n, data = d, from = from })
    n = d.extends
  end
  return chain
end

function M.builtin_names()
  local out = {}
  for k in pairs(require("story.sets")) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- The set in force: opts.set, else the POV's set, else the book's default.
function M.set_name(S, opts)
  opts = opts or {}
  return opts.set or (opts.pov and S.pov_sets[opts.pov]) or S.default_set
end

local function merge_rules(into, rules)
  local idx = {}
  for i, r in ipairs(into) do idx[r.id .. "\0" .. (r.tokens and table.concat(r.tokens, "|") or "")] = i end
  for _, r in ipairs(rules or {}) do
    local key = r.id .. "\0" .. (r.tokens and table.concat(r.tokens, "|") or "")
    if idx[key] then into[idx[key]] = r
    else
      -- a bare {id=, level=} overrides every rule with that id (e.g. level="off")
      local touched = false
      if not r.type then
        for i, x in ipairs(into) do if x.id == r.id then
          local c = {}
          for k, v in pairs(x) do c[k] = v end
          for k, v in pairs(r) do c[k] = v end
          into[i] = c; touched = true
        end end
      end
      if not touched and r.type then into[#into + 1] = r; idx[key] = #into end
    end
  end
end

-- -> E, the effective style: { name, chain, narration, voice, pov, exemplars, pairs, rules, allow, decode, slop }
function M.resolve(S, opts)
  local name = M.set_name(S, opts)
  local E = { name = name or "default", chain = {}, narration = S.base.narration, voice = {}, pov = {},
              exemplars = {}, pairs = {}, rules = {}, allow = {}, decode = {}, slop = { off = {} } }
  local layers = {}
  local chain, err = {}, nil
  if name then chain, err = M.chain(S, name) end
  if not chain then return nil, err end
  -- order: library/extended sets first (generic), then the book's base, then
  -- the named set itself when it is the book's own (most specific last)
  local own = chain[#chain]
  for i, c in ipairs(chain) do
    if not (i == #chain and own.from ~= "built-in") then layers[#layers + 1] = c.data end
    E.chain[#E.chain + 1] = c.name
  end
  layers[#layers + 1] = S.base
  if own and own.from ~= "built-in" then layers[#layers + 1] = own.data end
  local seen_allow = {}
  for _, L in ipairs(layers) do
    if L.narration then E.narration = L.narration end
    for _, v in ipairs(L.voice or {}) do E.voice[#E.voice + 1] = v end
    for k, v in pairs(L.pov or {}) do E.pov[k] = v end
    for _, x in ipairs(L.exemplars or {}) do E.exemplars[#E.exemplars + 1] = x end
    for _, x in ipairs(L.pairs or {}) do E.pairs[#E.pairs + 1] = x end
    merge_rules(E.rules, L.rules)
    for _, a in ipairs(L.allow or {}) do if not seen_allow[a] then seen_allow[a] = true; E.allow[#E.allow + 1] = a end end
    for k, v in pairs(L.decode or {}) do E.decode[k] = v end
    if L.slop == false then E.slop = false
    elseif type(L.slop) == "table" and E.slop then
      for k, v in pairs(L.slop) do
        if k == "off" then for _, x in ipairs(v) do E.slop.off[#E.slop.off + 1] = x end else E.slop[k] = v end
      end
    end
    if L.exemplar_set then E.exemplar_set = L.exemplar_set end
  end
  -- narration: the most specific SET that names one wins over the book's
  -- base (a first-person set must not inherit the manifest's "close third")
  local nar
  for _, c in ipairs(chain) do if c.data.narration then nar = c.data.narration end end
  if nar then E.narration = nar end
  for _, x in ipairs(S.dir_exemplars or {}) do E.exemplars[#E.exemplars + 1] = x end
  return E
end

-- ---- exemplars -------------------------------------------------------------------------------------
-- The mode of a passage (or of a beat's brief): dialogue, action, interior.
function M.mode_of(text, is_brief)
  local t = tostring(text or "")
  if is_brief then
    local l = t:lower()
    for _, w in ipairs{ "says", "say", "asks", "tells", "argue", "talk", "confront", "answers", "replies", "conversation", "interrogat" } do
      if l:find(w, 1, true) then return "dialogue" end
    end
    for _, w in ipairs{ "fight", "run", "chase", "attack", "grab", "shoot", "escape", "falls", "climb", "strike", "flee", "board", "crash" } do
      if l:find(w, 1, true) then return "action" end
    end
    return "interior"
  end
  local q, total = 0, #t
  for seg in t:gsub("\u{201C}", '"'):gsub("\u{201D}", '"'):gmatch('"[^"]*"') do q = q + #seg end
  if total > 0 and q / total > 0.3 then return "dialogue" end
  local u = lint.units(t)
  local words = 0
  for _, s in ipairs(u.sentences) do words = words + s.words end
  if #u.sentences >= 4 and words / #u.sentences < 10 then return "action" end
  return "interior"
end

-- 2-4 exemplars for a drafting step: the POV's (or unassigned) passages in
-- this set, golden first, one in the step's mode, the rest VARIED (not matched
-- on content), rotated by `seed` so a chapter doesn't see the same three.
function M.pick(E, opts)
  opts = opts or {}
  local k = opts.k or 3
  local pool = {}
  for _, x in ipairs(E.exemplars) do
    local set_ok = not x.set or x.set == E.name or x.set == E.exemplar_set
    for _, c in ipairs(E.chain) do if x.set == c then set_ok = true end end
    local pov_ok = not opts.pov or not x.pov or x.pov == opts.pov
    if set_ok and pov_ok then
      x.mode = x.mode or M.mode_of(x.text)
      pool[#pool + 1] = x
    end
  end
  if #pool == 0 then return {} end
  local seed = tonumber(opts.seed) or 0
  local function rot(list)
    if #list == 0 then return list end
    local out = {}
    for i = 1, #list do out[i] = list[((i - 1 + seed) % #list) + 1] end
    return out
  end
  local chosen, used, modes = {}, {}, {}
  local function take(x) if x and not used[x] and #chosen < k then used[x] = true; chosen[#chosen + 1] = x; modes[x.mode] = true end end
  local golden, same, other = {}, {}, {}
  for _, x in ipairs(pool) do
    if x.golden then golden[#golden + 1] = x end
    if x.mode == opts.mode then same[#same + 1] = x else other[#other + 1] = x end
  end
  take(rot(golden)[1])
  for _, x in ipairs(rot(same)) do if not used[x] then take(x); break end end
  for _, x in ipairs(rot(other)) do if not modes[x.mode] then take(x) end end
  for _, x in ipairs(rot(pool)) do take(x) end
  return chosen
end

-- ---- rules + checking ------------------------------------------------------------------------------
-- The effective rule list: the set's rules plus the slop pack (unless off).
function M.rules(E, book)
  local rules = {}
  for _, r in ipairs(E.rules) do rules[#rules + 1] = r end
  if E.slop ~= false then
    local ok, slop = pcall(require, "story.slop")
    if ok then
      local off = {}
      for _, id in ipairs(E.slop.off or {}) do off[id] = true end
      for _, r in ipairs(slop.rules(book, E.slop)) do if not off[r.id] then rules[#rules + 1] = r end end
    end
  end
  return rules
end

-- Check prose against the book's style in a set. -> lint result (+ .set)
function M.check(book, text, opts)
  opts = opts or {}
  local S = M.load(book)
  local E, err = M.resolve(S, opts)
  if not E then return nil, err end
  local meta = {}
  for _, s in ipairs(M.META_SECTIONS) do meta[#meta + 1] = s end
  for _, s in ipairs(book.m.drop_sections or {}) do meta[#meta + 1] = s end
  local r = lint.check(text, M.rules(E, book), { allow = E.allow, meta = meta,
    label = (opts.label or "text") .. (E.name ~= "default" and ("  [set " .. E.name .. "]") or "") })
  r.set = E.name
  return r
end

-- ---- what the drafter sees -------------------------------------------------------------------------
-- The voice card: narration + a few voice lines + this POV's line. Short, positive.
function M.voice_block(E, pov)
  local out = {}
  if E.narration then out[#out + 1] = "Narration: " .. E.narration .. "." end
  for i, v in ipairs(E.voice) do if i <= 6 then out[#out + 1] = v end end
  if pov and E.pov[pov] then out[#out + 1] = "This POV (" .. pov .. "): " .. E.pov[pov] end
  return table.concat(out, "\n")
end

function M.exemplar_block(list)
  local out = {}
  for _, x in ipairs(list) do
    out[#out + 1] = "--- " .. (x.pov and (x.pov .. ", ") or "") .. (x.mode or "") .. " ---\n" .. x.text
  end
  return table.concat(out, "\n\n")
end

-- ---- the guide (reference for revision) -------------------------------------------------------------
local function interp(s, limits)
  return (s:gsub("{{([%w_]+)}}", function(k) return tostring(limits[k] or ("{{" .. k .. "}}")) end))
end

function M.pull(S, names)
  local bits = (S.guide and S.guide.bits) or {}
  names = (names and #names > 0) and names or (S.guide and S.guide.order) or {}
  local out = {}
  for _, n in ipairs(names) do
    if bits[n] then out[#out + 1] = interp((bits[n]:gsub("%s+$", "")), S.limits or {}) end
  end
  return table.concat(out, "\n\n")
end

-- The guide sections behind failed rules (rule.guide = "bit_name"), for a
-- regeneration or a reviser -- never the whole guide.
function M.guide_for(S, E, findings)
  local want, seen = {}, {}
  local by_id = {}
  for _, r in ipairs(E.rules) do if r.guide then by_id[r.id] = r.guide end end
  for _, f in ipairs(findings or {}) do
    local g = by_id[f.id]
    if g and not seen[g] then seen[g] = true; want[#want + 1] = g end
  end
  return M.pull(S, want)
end

function M.render(S, title)
  local E = M.resolve(S) or { voice = {}, name = "default" }
  local out = { "# Style — " .. (title or "the book"),
    "*Generated from .boggart/style.lua -- edit that file; this one is an export.*", "" }
  if #E.voice > 0 then
    out[#out + 1] = "## Voice"
    for _, v in ipairs(E.voice) do out[#out + 1] = "- " .. v end
    out[#out + 1] = ""
  end
  local g = M.pull(S, nil)
  if g ~= "" then out[#out + 1] = g end
  return table.concat(out, "\n")
end

return M
