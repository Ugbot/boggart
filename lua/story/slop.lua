-- story/slop.lua -- LLM tells: a built-in pack, the book's own accepted bans,
-- and a profiler that finds what THIS model over-uses against THIS author.
--
-- The pack is WARNINGS by default: practitioners who police every hit end up
-- "back toward the AI-generated median" (Slate, 2026), and every slop list is
-- topic-skewed. A book raises what it cares about (rules = { { id =
-- "Slop.NotButY", level = "error" } }) or turns items off (slop = { off = {...} }).
--
-- The profiler is the Antislop method (ICLR 2026) at book scale: n-grams whose
-- rate in the model's drafts is far above their rate in the author's own prose
-- are PROPOSED as bans -- the author accepts them (/story proposal accept), and
-- they land in <book>/.boggart/style/slop.json. The list grows from data, not
-- from someone else's idea of slop.
local M = {}

M.PACK = {
  { id = "Slop.Phrase", type = "existence", level = "warning", message = "AI tell: '{token}'",
    tokens = { "tapestry", "delve", "delved", "a testament to", "palpable", "a symphony of", "a kaleidoscope of",
      "an intricate dance", "a dance of", "ministrations", "unbidden", "barely above a whisper", "a wave of",
      "couldn't help but", "sent shivers", "shivers down", "shiver down", "a breath he didn't know",
      "a breath she didn't know", "hung heavy in the air", "hung in the air", "in that moment", "little did",
      "something shifted", "the silence stretched", "maybe, just maybe", "a flicker of", "the ghost of a smile",
      "mischievous glint", "eyes sparkled", "a beacon of", "the air was thick with",
      "every fiber of", "in the grand scheme", "whispered promises" } },
  { id = "Slop.NotButY", type = "existence", level = "warning", message = "'not X, but Y' construction",
    tokens = { "~not [%a']+, but ", "~it wasn't [%a' ]-%. it was", "~wasn't just [%a' ]-, it was",
      "~not because [%a' ]-, but because", "~not [%a']+ %- [%a']+, but " } },
  { id = "Slop.Adjacent", type = "repetition", what = "adjacent", level = "warning", message = "doubled word '{word} {word}'" },
  { id = "Slop.EmDash", type = "occurrence", scope = "paragraph", tokens = { "\u{2014}" }, max = 2, level = "suggestion",
    message = "{n} em dashes in one paragraph" },
  { id = "Slop.Repeat", type = "repetition", what = "ngram", n = 4, max = 2, scope = "text", level = "suggestion" },
}

local function slop_path(root) return root .. "/.boggart/style/slop.json" end

function M.book_bans(root)
  local f = io.open(slop_path(root), "rb")
  if not f then return {} end
  local ok, t = pcall(require("json").decode, f:read("a"))
  f:close()
  return (ok and type(t) == "table" and t.bans) or {}
end

-- The pack plus the book's own bans (one existence rule per level).
function M.rules(book, cfg)
  local out = {}
  for _, r in ipairs(M.PACK) do out[#out + 1] = r end
  if book and book.root then
    local by = {}
    for _, b in ipairs(M.book_bans(book.root)) do
      local lv = b.level or "warning"
      by[lv] = by[lv] or {}
      table.insert(by[lv], b.phrase)
    end
    for lv, toks in pairs(by) do
      out[#out + 1] = { id = "Slop.Book", type = "existence", level = lv, tokens = toks,
                        message = "over-used by the model in this book: '{token}'" }
    end
  end
  return out
end

-- Add a ban (the author's accept of a proposal, or a direct /story command).
function M.add_ban(root, phrase, level, note)
  phrase = tostring(phrase or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if phrase == "" then return nil, "empty phrase" end
  local bans = M.book_bans(root)
  for _, b in ipairs(bans) do if b.phrase == phrase then return phrase .. " (already banned)" end end
  bans[#bans + 1] = { phrase = phrase, level = level or "warning", note = note }
  table.sort(bans, function(a, b) return a.phrase < b.phrase end)
  sys.mkdir_p(root .. "/.boggart/style")
  local lines = {}
  for _, b in ipairs(bans) do lines[#lines + 1] = "    " .. require("json").encode(b) end
  local f = assert(io.open(slop_path(root), "wb"))
  f:write('{\n  "bans": [\n', table.concat(lines, ",\n"), "\n  ]\n}\n")
  f:close()
  return phrase
end

-- ---- the profiler --------------------------------------------------------------------------------
M.STOP = {}
for w in ([[a an the and or but of to in on at for with by from as is was were be been had has have
  he she it they them his her its their i you we me my your our him us this that these those there then
  than so if not no do did does said says what when where who how which would could should will can]]):gmatch("%a+") do
  M.STOP[w] = true
end

-- n-gram counts (n = 2..4) over texts, and the total word count.
function M.profile(texts, nmin, nmax)
  nmin, nmax = nmin or 2, nmax or 4
  local counts, total = {}, 0
  for _, t in ipairs(texts) do
    local ws = {}
    for w in tostring(t):lower():gsub("\u{2019}", "'"):gmatch("[%a']+") do ws[#ws + 1] = w end
    total = total + #ws
    for n = nmin, nmax do
      for i = 1, #ws - n + 1 do
        local g = table.concat(ws, " ", i, i + n - 1)
        counts[g] = (counts[g] or 0) + 1
      end
    end
  end
  return counts, total
end

local function content(g)
  for w in g:gmatch("[%a']+") do if not M.STOP[w] then return true end end
  return false
end

-- Grams far more frequent in `drafts` than in `base` (the author's prose).
-- -> { {gram, draft = per 10k words, base = per 10k, ratio, count} } best first
function M.overrep(drafts, base, opts)
  opts = opts or {}
  local dc, dt = M.profile(drafts)
  local bc, bt = M.profile(base)
  if dt == 0 then return {} end
  bt = math.max(bt, 1)
  local out = {}
  for g, c in pairs(dc) do
    if c >= (opts.min_count or 3) and content(g) then
      local dr = c * 10000 / dt
      local br = ((bc[g] or 0) + 0.5) * 10000 / bt   -- +0.5: unseen in the author is not infinite
      local ratio = dr / br
      if ratio >= (opts.ratio or 5) then out[#out + 1] = { gram = g, count = c, draft = dr, base = br, ratio = ratio } end
    end
  end
  table.sort(out, function(a, b) return a.ratio > b.ratio or (a.ratio == b.ratio and a.gram < b.gram) end)
  -- keep the longest: drop a gram contained in a stronger kept one
  local kept = {}
  for _, o in ipairs(out) do
    local sub = false
    for _, k in ipairs(kept) do if k.gram:find(o.gram, 1, true) then sub = true; break end end
    if not sub then kept[#kept + 1] = o end
    if #kept >= (opts.limit or 20) then break end
  end
  return kept
end

return M
