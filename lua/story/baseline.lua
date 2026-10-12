-- story/baseline.lua -- the author's stylometric fingerprint, and drift from it.
--
-- No published method measures style drift WITHIN one book (the research gap
-- in docs/story-style.md); this is ours. Plain, explainable markers -- no
-- model -- measured on the author's approved prose, and every chapter or AI
-- edit compared against the author's own chapter-to-chapter spread:
-- "2.3 sd fewer contractions than your chapters", not "sentence too long".
--
-- AI revision pulls every voice the same way (van Nuenen 2026: fewer
-- contractions, function words and first-person pronouns; longer words, wider
-- vocabulary, fancier punctuation). `normalization` scores movement along
-- exactly that direction, so an edit that flattens the voice is caught even
-- when every marker is individually "within range".
local lint = require("story.lint")
local M = {}

local FUNCTION = {}
for w in ([[a an the and or but of to in on at for with by from as is was were be been being had has have
  it its this that these those there then than so if not no do did does which who whom what when where while
  up out over into about after before under again just only very too all any some each such own same can will
  would could should may might must shall]]):gmatch("%a+") do FUNCTION[w] = true end
local FIRST = { i = true, me = true, my = true, mine = true, myself = true, we = true, us = true, our = true }

M.MARKERS = {
  "sent_mean", "sent_sd", "sent_p90", "para_words", "contractions", "function_words", "first_person",
  "word_len", "ttr", "em_dash", "semicolon", "colon", "ellipsis", "exclaim", "question", "comma",
  "dialogue_share", "opener_variety",
}
M.LABEL = {
  sent_mean = "average sentence length", sent_sd = "sentence-length spread", sent_p90 = "long-sentence length (p90)",
  para_words = "paragraph length", contractions = "contractions per 100 words", function_words = "function-word share",
  first_person = "first-person pronouns per 100 words", word_len = "average word length", ttr = "vocabulary variety",
  em_dash = "em dashes per 100 words", semicolon = "semicolons per 100 words", colon = "colons per 100 words",
  ellipsis = "ellipses per 100 words", exclaim = "exclamations per 100 words", question = "questions per 100 words",
  comma = "commas per 100 words", dialogue_share = "share of words in dialogue", opener_variety = "sentence-opener variety",
}
-- the direction AI revision moves prose (sign: +1 = AI edits raise it)
M.NORMALIZE = { contractions = -1, function_words = -1, first_person = -1, word_len = 1, ttr = 1, semicolon = 1, colon = 1 }

local function count(s, plain)
  local n, i = 0, 1
  while true do
    local a, b = s:find(plain, i, true)
    if not a then return n end
    n = n + 1
    i = b + 1
  end
end

-- -> markers for one text, or nil when too short to mean anything
function M.features(text)
  local u = lint.units(tostring(text or ""))
  local words = {}
  local raw = {}
  for _, l in ipairs(u.lines) do raw[#raw + 1] = l.text end
  local body = table.concat(raw, "\n"):gsub("\u{2019}", "'")
  for w in body:lower():gmatch("[%a']+") do words[#words + 1] = w end
  local nw = #words
  if nw < 80 or #u.sentences < 4 then return nil end
  local lens = {}
  local sum = 0
  for _, s in ipairs(u.sentences) do lens[#lens + 1] = s.words; sum = sum + s.words end
  table.sort(lens)
  local mean = sum / #lens
  local var = 0
  for _, l in ipairs(lens) do var = var + (l - mean) ^ 2 end
  local contractions, fn, fp, chars = 0, 0, 0, 0
  for _, w in ipairs(words) do
    if w:find("'", 1, true) and (w:match("n't$") or w:match("'[sdm]$") or w:match("'re$") or w:match("'ll$") or w:match("'ve$")) then
      contractions = contractions + 1
    end
    if FUNCTION[w] then fn = fn + 1 end
    if FIRST[w] then fp = fp + 1 end
    chars = chars + #w
  end
  -- moving type/token ratio over 200-word windows (length-independent)
  local ttr, windows = 0, 0
  for i = 1, nw - 199, 100 do
    local seen, types = {}, 0
    for j = i, i + 199 do if not seen[words[j]] then seen[words[j]] = true; types = types + 1 end end
    ttr = ttr + types / 200
    windows = windows + 1
  end
  if windows == 0 then
    local seen, types = {}, 0
    for _, w in ipairs(words) do if not seen[w] then seen[w] = true; types = types + 1 end end
    ttr, windows = types / nw, 1
  end
  local dq = body:gsub("\u{201C}", '"'):gsub("\u{201D}", '"')
  local dlg = 0
  for seg in dq:gmatch('"([^"]*)"') do for _ in seg:gmatch("%S+") do dlg = dlg + 1 end end
  local openers = {}
  local distinct = 0
  for _, s in ipairs(u.sentences) do
    local f = (lint.unquote(s.text):match("^%s*(%a+)") or ""):lower()
    if f ~= "" and not openers[f] then openers[f] = true; distinct = distinct + 1 end
  end
  local per100 = function(c) return c * 100 / nw end
  return {
    sent_mean = mean, sent_sd = math.sqrt(var / #lens), sent_p90 = lens[math.max(1, math.floor(#lens * 0.9))],
    para_words = nw / math.max(1, #u.lines), contractions = per100(contractions), function_words = fn / nw,
    first_person = per100(fp), word_len = chars / nw, ttr = ttr / windows,
    em_dash = per100(count(body, "\u{2014}")), semicolon = per100(count(body, ";")), colon = per100(count(body, ":")),
    ellipsis = per100(count(body, "...") + count(body, "\u{2026}")), exclaim = per100(count(body, "!")),
    question = per100(count(body, "?")), comma = per100(count(body, ",")), dialogue_share = dlg / nw,
    opener_variety = distinct / #u.sentences,
  }, nw
end

-- A baseline from several texts (one per chapter or exemplar): mean and
-- spread per marker. With too few texts the spread falls back to a share of
-- the mean, so z-scores stay honest rather than exploding.
function M.build(texts, sources)
  local rows = {}
  for _, t in ipairs(texts) do
    local f = M.features(t)
    if f then rows[#rows + 1] = f end
  end
  if #rows == 0 then return nil, "no text long enough to measure (need about 80 words per sample)" end
  local B = { n = #rows, sources = sources or {}, markers = {} }
  for _, k in ipairs(M.MARKERS) do
    local s = 0
    for _, r in ipairs(rows) do s = s + r[k] end
    local mean = s / #rows
    local v = 0
    for _, r in ipairs(rows) do v = v + (r[k] - mean) ^ 2 end
    local sd = #rows > 1 and math.sqrt(v / (#rows - 1)) or 0
    -- floor: at least 15% of the mean (or a small absolute), so one quiet marker can't dominate
    sd = math.max(sd, math.abs(mean) * 0.15, 0.02)
    B.markers[k] = { mean = mean, sd = sd }
  end
  return B
end

-- -> { markers = { {key, label, value, mean, z} ... sorted by |z| }, flagged, normalization, words }
function M.drift(text, B, opts)
  opts = opts or {}
  local f, nw = M.features(text)
  if not f then return nil, "too short to measure (about 80 words minimum)" end
  local out = { markers = {}, flagged = {}, words = nw }
  local norm, nn = 0, 0
  for _, k in ipairs(M.MARKERS) do
    local m = B.markers[k]
    if m then
      local z = (f[k] - m.mean) / m.sd
      local row = { key = k, label = M.LABEL[k], value = f[k], mean = m.mean, z = z }
      out.markers[#out.markers + 1] = row
      if math.abs(z) >= (opts.z or 2) then out.flagged[#out.flagged + 1] = row end
      if M.NORMALIZE[k] then norm = norm + M.NORMALIZE[k] * z; nn = nn + 1 end
    end
  end
  table.sort(out.markers, function(a, b) return math.abs(a.z) > math.abs(b.z) end)
  table.sort(out.flagged, function(a, b) return math.abs(a.z) > math.abs(b.z) end)
  out.normalization = nn > 0 and norm / nn or 0
  return out
end

-- Before -> after for an edit, no baseline needed: how far the edit moved the
-- prose along the AI-normalization direction (positive = flattened).
function M.edit_shift(before, after)
  local a, b = M.features(before), M.features(after)
  if not (a and b) then return nil end
  local B = M.build({ before })
  if not B then return nil end
  local d = M.drift(after, B, { z = 1.5 })
  return d
end

local function fmtv(v) return (math.abs(v) >= 10) and string.format("%.0f", v) or string.format("%.2f", v) end

function M.report(d, label)
  local out = { "== drift: " .. (label or "text") .. " (" .. d.words .. " words) ==" }
  if #d.flagged == 0 then
    out[#out + 1] = "within your own range on every marker"
  else
    for _, r in ipairs(d.flagged) do
      out[#out + 1] = string.format("%-38s %s  (yours %s)  %+.1f sd", r.label, fmtv(r.value), fmtv(r.mean), r.z)
    end
  end
  out[#out + 1] = string.format("AI-normalization score %+.2f  (%s)", d.normalization,
    d.normalization >= 1.5 and "FLATTENED: moved the way AI revision moves prose"
    or d.normalization >= 0.75 and "leaning toward the AI median" or "no normalizing drift")
  return table.concat(out, "\n")
end

-- ---- stored per book ------------------------------------------------------------------------------
function M.path(root) return root .. "/.boggart/style/baseline.json" end

function M.save(root, B)
  sys.mkdir_p(root .. "/.boggart/style")
  local keys = {}
  local lines = {}
  for _, k in ipairs(M.MARKERS) do
    local m = B.markers[k]
    lines[#lines + 1] = string.format('    "%s": {"mean": %.6g, "sd": %.6g}', k, m.mean, m.sd)
  end
  local src = {}
  for _, s in ipairs(B.sources or {}) do src[#src + 1] = require("json").encode(s) end
  local f = assert(io.open(M.path(root), "wb"))
  f:write('{\n  "n": ', tostring(B.n), ',\n  "sources": [', table.concat(src, ", "), '],\n  "markers": {\n',
    table.concat(lines, ",\n"), "\n  }\n}\n")
  f:close()
  return M.path(root)
end

function M.load(root)
  local f = io.open(M.path(root), "rb")
  if not f then return nil end
  local ok, t = pcall(require("json").decode, f:read("a"))
  f:close()
  return ok and t or nil
end

return M
