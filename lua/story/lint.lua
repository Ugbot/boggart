-- story/lint.lua -- the prose checker: typed rules with severities, modelled
-- on Vale (docs/story-style.md). Pure functions over text; no store, no model.
--
-- A rule:
--   { id = "Book.TheWay", type = "occurrence", level = "warning", scope = "text",
--     tokens = { "the way" }, exceptions = { "on the way", ... }, max = 3,
--     message = "'the way' {n} times (budget {max})" }
--
-- types      existence    tokens / patterns found anywhere (bans, tells)
--            substitution swap = { ["bad"] = "good" }
--            occurrence   count of tokens/patterns per scope vs max/min (budgets, refrains)
--            repetition   what = "opener" (same first word, run = N sentences)
--                         | "ngram" (n = 3, max = 2 per scope) | "adjacent" ("the the")
--            consistency  pairs = { {"Kolya", "Kolia"} } -- two spellings in one text
--            conditional  first = token, second = token -- first used without the second
--            metric       metric = sentence_max | avg_sentence | similes_per_line |
--                         simile_density | media_opener, with max / min
-- levels     suggestion | warning | error -- only an error fails the check
-- scope      text | paragraph | sentence (where counts are taken)
--
-- The author stays in charge of the voice:
--   * allow = { "Book.OpenerRun" }  -- a deliberate device: its findings drop to
--     suggestions ("allowed") instead of warnings/errors;
--   * <!-- style off: Book.OpenerRun, Book.AndChain --> ... <!-- style on -->
--     in the manuscript suppresses those rules (or all, with no names) for the
--     lines between; every suppression is listed in the report.
local M = {}

M.LEVELS = { suggestion = 1, warning = 2, error = 3 }

-- ---- text into units --------------------------------------------------------------------
-- Lines of narration with their line numbers: blockquotes (diegetic documents)
-- skipped, nothing after a meta heading, and suppression comments tracked.
function M.units(text, opts)
  opts = opts or {}
  local stops = {}
  for _, s in ipairs(opts.meta or {}) do stops[#stops + 1] = s:lower() end
  local lines, off = {}, {}
  local all_off, idx = false, 0
  local suppressed = {}
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    idx = idx + 1
    local cmd, names = line:match("<!%-%-%s*style%s+(o[nf]f?)%s*:?%s*(.-)%s*%-%->")
    if cmd then
      if cmd == "on" then off = {}; all_off = false
      elseif names == "" then all_off = true
      else for n in names:gmatch("[^,%s]+") do off[n] = true end end
    else
      local h = line:match("^%s*#+%s*(.-)%s*$")
      local stop = false
      if h then
        for _, s in ipairs(stops) do if h:lower():find(s, 1, true) == 1 then stop = true end end
      end
      if stop then break end
      if line:match("%S") and not line:match("^%s*>") and not line:match("^%s*#") then
        local o = {}
        for k in pairs(off) do o[k] = true end
        lines[#lines + 1] = { n = idx, text = line, off = o, all_off = all_off }
      end
    end
  end
  -- sentences, each knowing its line
  local sentences = {}
  for _, l in ipairs(lines) do
    local rest = l.text
    for s in rest:gmatch("[^%.!%?]+[%.!%?]*") do
      local w = 0
      for _ in s:gmatch("%S+") do w = w + 1 end
      if w > 0 and s:match("%a") then sentences[#sentences + 1] = { text = s, words = w, line = l.n, unit = l } end
    end
  end
  return { lines = lines, sentences = sentences, suppressed = suppressed }
end

-- Quote marks are multi-byte in curly form: strip them as strings, never in a [class].
M.QUOTES = { "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", '"', "'" }
function M.unquote(s)
  s = tostring(s):gsub("^%s+", "")
  local changed = true
  while changed do
    changed = false
    for _, q in ipairs(M.QUOTES) do
      if s:sub(1, #q) == q then s = s:sub(#q + 1); changed = true end
    end
  end
  return s
end

-- Narration only: dialogue in straight or curly double quotes removed.
function M.narration(s)
  s = tostring(s):gsub("\u{201C}", '"'):gsub("\u{201D}", '"')
  return (s:gsub('"[^"]*"', " "))
end

local function esc(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

-- A token as a Lua pattern: words match whole (frontier), marks anywhere; a
-- token that starts with "~" is used as a raw Lua pattern.
local function token_pat(tok, ignorecase)
  if tok:sub(1, 1) == "~" then return tok:sub(2) end
  local t = ignorecase and tok:lower() or tok
  if t:find("%a") then
    local p = esc(t)
    if t:sub(1, 1):match("%a") then p = "%f[%w]" .. p end
    if t:sub(-1):match("%a") then p = p .. "%f[%W]" end
    return p
  end
  return esc(t)
end

M.token_pattern = token_pat

local function count_in(s, pat)
  local n = 0
  local i = 1
  while true do
    local a, b = s:find(pat, i)
    if not a then break end
    n = n + 1
    i = (b >= a) and (b + 1) or (a + 1)
  end
  return n
end

local function hits(rule, s)
  local ic = rule.ignorecase ~= false
  local hay = ic and s:lower() or s
  local found = {}
  for _, tok in ipairs(rule.tokens or {}) do
    local c = count_in(hay, token_pat(tok, ic))
    if c > 0 then
      for _, ex in ipairs(rule.exceptions or {}) do
        -- an exception that contains the token cancels that many hits
        c = c - count_in(hay, token_pat(ex, ic))
      end
      if c > 0 then found[#found + 1] = { token = tok, n = c } end
    end
  end
  return found
end

local function fmt(msg, vars)
  return (tostring(msg or ""):gsub("{(%w+)}", function(k) return vars[k] ~= nil and tostring(vars[k]) or ("{" .. k .. "}") end))
end

-- ---- similes (the comparisons the books budget) -----------------------------------------------------
M.SIMILE_IDIOMS = { "on the way", "in the way", "by the way", "out of the way", "the way out", "the way back",
  "the way home", "the way in", "would like", "i'd like", "you'd like", "feel like", "felt like", "feels like",
  "looks like", "look like", "looked like", "likely", "liked", "likes", "unlike", "like this", "like that",
  "just like", "something like", "anything like", "nothing like", "things like", "people like" }
function M.simile_count(s)
  local l = s:lower()
  local n = count_in(l, "%f[%a]the way%f[%A]") + count_in(l, "%f[%a]like%f[%A]")
  for _, idm in ipairs(M.SIMILE_IDIOMS) do n = n - count_in(l, token_pat(idm, true)) end
  return math.max(0, n)
end

-- ---- the rule types ----------------------------------------------------------------------------------
local check = {}

check.existence = function(rule, u, emit)
  for _, l in ipairs(u.lines) do
    for _, h in ipairs(hits(rule, l.text)) do
      emit(l, fmt(rule.message or "'{token}'", { token = h.token, n = h.n }))
    end
  end
end

check.substitution = function(rule, u, emit)
  for _, l in ipairs(u.lines) do
    for bad, good in pairs(rule.swap or {}) do
      if count_in(l.text:lower(), token_pat(bad, true)) > 0 then
        emit(l, fmt(rule.message or "'{bad}' -> prefer '{good}'", { bad = bad, good = good }))
      end
    end
  end
end

local function scoped_units(rule, u)
  local scope = rule.scope or "text"
  if scope == "text" then
    local all = {}
    for _, l in ipairs(u.lines) do all[#all + 1] = l.text end
    return { { text = table.concat(all, "\n"), line = u.lines[1] } }
  elseif scope == "sentence" then
    local out = {}
    for _, s in ipairs(u.sentences) do out[#out + 1] = { text = s.text, line = s.unit } end
    return out
  end
  local out = {}
  for _, l in ipairs(u.lines) do out[#out + 1] = { text = l.text, line = l } end
  return out
end

check.occurrence = function(rule, u, emit)
  for _, su in ipairs(scoped_units(rule, u)) do
    local n = 0
    local where = {}
    for _, h in ipairs(hits(rule, su.text)) do n = n + h.n end
    if rule.max and n > rule.max or rule.min and n < rule.min then
      -- locate: the lines that hold the hits
      if (rule.scope or "text") == "text" then
        for _, l in ipairs(u.lines) do
          if #hits(rule, l.text) > 0 then where[#where + 1] = l.n end
        end
      end
      emit(su.line, fmt(rule.message or "{n} (max {max})", { n = n, max = rule.max, min = rule.min,
        lines = table.concat(where, ", ") }), where)
    end
  end
end

check.repetition = function(rule, u, emit)
  local what = rule.what or "opener"
  if what == "opener" then
    local run, prev, start = 0, nil, nil
    local need = rule.run or 3
    for _, s in ipairs(u.sentences) do
      local f = (M.unquote(s.text):match("^%s*(%a+)") or ""):lower()
      if f ~= "" and f == prev then run = run + 1 else run = 1; start = s end
      prev = f
      if run == need then
        emit(start.unit, fmt(rule.message or "{run} sentences in a row open with '{word}'", { run = need, word = f }))
      end
    end
  elseif what == "adjacent" then
    for _, l in ipairs(u.lines) do
      local low = l.text:lower()
      for w in low:gmatch("%f[%a](%a+)%s+%1%f[%A]") do
        if w ~= "had" and w ~= "that" then emit(l, fmt(rule.message or "'{word} {word}'", { word = w })) end
      end
    end
  elseif what == "ngram" then
    local n, max = rule.n or 3, rule.max or 2
    for _, su in ipairs(scoped_units(rule, u)) do
      local ws = {}
      for w in su.text:lower():gmatch("[%a']+") do ws[#ws + 1] = w end
      local counts = {}
      for i = 1, #ws - n + 1 do
        local g = table.concat(ws, " ", i, i + n - 1)
        counts[g] = (counts[g] or 0) + 1
      end
      local over = {}
      for g, c in pairs(counts) do if c > max then over[#over + 1] = { g = g, c = c } end end
      table.sort(over, function(a, b) return a.c > b.c or (a.c == b.c and a.g < b.g) end)
      for i = 1, math.min(#over, 5) do
        emit(su.line, fmt(rule.message or "'{gram}' repeated {n} times", { gram = over[i].g, n = over[i].c }))
      end
    end
  end
end

check.consistency = function(rule, u, emit)
  local all = {}
  for _, l in ipairs(u.lines) do all[#all + 1] = l.text end
  local text = table.concat(all, "\n"):lower()
  for _, pair in ipairs(rule.pairs or {}) do
    local a = count_in(text, token_pat(pair[1], true))
    local b = count_in(text, token_pat(pair[2], true))
    if a > 0 and b > 0 then
      emit(u.lines[1], fmt(rule.message or "both '{a}' ({na}) and '{b}' ({nb})", { a = pair[1], b = pair[2], na = a, nb = b }))
    end
  end
end

check.conditional = function(rule, u, emit)
  local all = {}
  for _, l in ipairs(u.lines) do all[#all + 1] = l.text end
  local text = table.concat(all, "\n"):lower()
  if count_in(text, token_pat(rule.first, true)) > 0 and count_in(text, token_pat(rule.second, true)) == 0 then
    emit(u.lines[1], fmt(rule.message or "'{first}' without '{second}'", { first = rule.first, second = rule.second }))
  end
end

local metrics = {}
metrics.sentence_max = function(rule, u, emit)
  local cap = rule.max or 45
  for _, s in ipairs(u.sentences) do
    if s.words > cap then emit(s.unit, fmt(rule.message or "sentence of {n} words (max {max})", { n = s.words, max = cap })) end
  end
end
metrics.avg_sentence = function(rule, u, emit)
  if #u.sentences < (rule.min_sentences or 5) then return end
  local total = 0
  for _, s in ipairs(u.sentences) do total = total + s.words end
  local avg = math.floor(total / #u.sentences * 10) / 10
  if rule.max and avg > rule.max or rule.min and avg < rule.min then
    emit(u.lines[1], fmt(rule.message or "average sentence {n} words", { n = avg, max = rule.max, min = rule.min }))
  end
end
metrics.similes_per_line = function(rule, u, emit)
  for _, l in ipairs(u.lines) do
    local n = M.simile_count(l.text)
    if n > (rule.max or 1) then emit(l, fmt(rule.message or "{n} comparisons on one line (max {max})", { n = n, max = rule.max or 1 })) end
  end
end
metrics.simile_density = function(rule, u, emit)
  local n, w = 0, 0
  for _, l in ipairs(u.lines) do
    n = n + M.simile_count(l.text)
    for _ in l.text:gmatch("%S+") do w = w + 1 end
  end
  local per = rule.per_words or 150
  if w > 0 and n / w > 1 / per then
    emit(u.lines[1], fmt(rule.message or "{n} comparisons in {w} words (max 1 per {per})", { n = n, w = w, per = per }))
  end
end
metrics.media_opener = function(rule, u, emit, text)
  local i, first = 0, nil
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    i = i + 1
    if line:match("%S") and not line:match("^%s*#") and not line:match("<!%-%-") then first = { n = i, text = line }; break end
  end
  if first and not (first.text:match("^%s*>") or first.text:match("^%-%-%-")) then
    emit({ n = first.n, off = {}, text = first.text }, rule.message or "the chapter does not open on a media artifact")
  end
end
-- Person and tense are measured in NARRATION (dialogue removed), per chunk of
-- about 200 words, so one chapter can report where it slipped.
local PAST = { "was", "were", "had", "did", "said", "went", "came", "saw", "knew", "thought", "felt", "looked", "turned" }
local PRESENT = { "is", "are", "am", "has", "does", "says", "goes", "comes", "sees", "knows", "thinks", "feels", "looks", "turns" }
local FIRST = { "i", "me", "my", "mine", "myself" }
local function tally(words, list)
  local set, n = {}, 0
  for _, w in ipairs(list) do set[w] = true end
  for _, w in ipairs(words) do if set[w] then n = n + 1 end end
  return n
end
local function narration_chunks(u, size)
  local chunks, cur, first_line = {}, {}, nil
  for _, l in ipairs(u.lines) do
    first_line = first_line or l
    for w in M.narration(l.text):lower():gmatch("[%a']+") do cur[#cur + 1] = w end
    if #cur >= size then chunks[#chunks + 1] = { words = cur, line = first_line }; cur = {}; first_line = nil end
  end
  if #cur >= size / 2 then chunks[#chunks + 1] = { words = cur, line = first_line } end
  return chunks
end
metrics.tense = function(rule, u, emit)
  local want = rule.tense or "past"
  for _, c in ipairs(narration_chunks(u, rule.chunk or 200)) do
    local past, pres = tally(c.words, PAST), tally(c.words, PRESENT)
    local wrong, right = want == "past" and pres or past, want == "past" and past or pres
    if wrong + right >= 6 and wrong > (rule.max_share or 0.4) * (wrong + right) then
      emit(c.line, fmt(rule.message or "narration drifts out of {tense} tense ({wrong} of {total} tense markers)",
        { tense = want, wrong = wrong, total = wrong + right }))
    end
  end
end
metrics.person = function(rule, u, emit)
  local want = rule.person or "third"
  for _, c in ipairs(narration_chunks(u, rule.chunk or 200)) do
    local fp = tally(c.words, FIRST)
    local per100 = fp * 100 / #c.words
    if want == "third" and per100 > (rule.max_first or 1.5) then
      emit(c.line, fmt(rule.message or "first-person narration ({n} I/me/my in {w} words) in a third-person set",
        { n = fp, w = #c.words }))
    elseif want == "first" and fp == 0 and #c.words >= (rule.chunk or 200) / 2 then
      emit(c.line, fmt(rule.message or "no first-person narration in {w} words of a first-person set", { w = #c.words }))
    end
  end
end

check.metric = function(rule, u, emit, text)
  local fn = metrics[rule.metric or ""]
  if fn then fn(rule, u, emit, text) end
end
M.metrics = metrics

-- ---- running a rule set -----------------------------------------------------------------------------
-- -> result { findings = { {id, level, line, message, lines} }, errors, warnings,
--             suggestions, suppressed = { id = count }, stats, verdict, report }
function M.check(text, rules, opts)
  opts = opts or {}
  local u = M.units(text, opts)
  local allow = {}
  for _, id in ipairs(opts.allow or {}) do allow[id] = true end
  local findings, suppressed = {}, {}
  for _, rule in ipairs(rules or {}) do
    local fn = check[rule.type or ""]
    if fn and rule.level ~= "off" then
      fn(rule, u, function(line, msg, lines)
        line = line or { n = 0, off = {} }
        if line.all_off or (line.off and line.off[rule.id]) then
          suppressed[rule.id] = (suppressed[rule.id] or 0) + 1
          return
        end
        local level = rule.level or "warning"
        local allowed = allow[rule.id] or (rule.tag and allow[rule.tag])
        if allowed then level = "suggestion" end
        findings[#findings + 1] = { id = rule.id, level = level, line = line.n, message = msg,
                                    allowed = allowed and true or nil, lines = lines }
      end, text)
    end
  end
  table.sort(findings, function(a, b)
    local la, lb = M.LEVELS[a.level] or 0, M.LEVELS[b.level] or 0
    if la ~= lb then return la > lb end
    if a.line ~= b.line then return a.line < b.line end
    return a.id < b.id
  end)
  local c = { error = 0, warning = 0, suggestion = 0 }
  for _, f in ipairs(findings) do c[f.level] = (c[f.level] or 0) + 1 end
  local words, total = 0, 0
  local maxw = 0
  for _, s in ipairs(u.sentences) do total = total + s.words; if s.words > maxw then maxw = s.words end end
  for _, l in ipairs(u.lines) do for _ in l.text:gmatch("%S+") do words = words + 1 end end
  local stats = { sentences = #u.sentences, words = words, max = maxw,
                  avg = #u.sentences > 0 and (math.floor(total / #u.sentences * 10) / 10) or 0 }
  local r = { findings = findings, errors = c.error, warnings = c.warning, suggestions = c.suggestion,
              suppressed = suppressed, stats = stats, verdict = c.error == 0 and "PASS" or "FAIL" }
  r.report = M.report(r, opts.label)
  return r
end

local TAG = { error = "ERROR  ", warning = "warning", suggestion = "note   " }
function M.report(r, label)
  local out = { "== " .. (label or "text") .. " ==",
    string.format("%d words, %d sentences, average %s, longest %d", r.stats.words, r.stats.sentences,
      tostring(r.stats.avg), r.stats.max) }
  for _, f in ipairs(r.findings) do
    out[#out + 1] = string.format("%s %-20s %s%s%s", TAG[f.level] or f.level, f.id,
      f.line and f.line > 0 and ("line " .. f.line .. ": ") or "", f.message, f.allowed and "  (allowed device)" or "")
  end
  local sup = {}
  for id, n in pairs(r.suppressed) do sup[#sup + 1] = id .. " x" .. n end
  table.sort(sup)
  if #sup > 0 then out[#out + 1] = "suppressed in the text: " .. table.concat(sup, ", ") end
  local errs = {}
  for _, f in ipairs(r.findings) do if f.level == "error" then errs[#errs + 1] = f.id end end
  out[#out + 1] = string.format("VERDICT: %s (%d errors, %d warnings, %d notes)%s", r.verdict, r.errors, r.warnings,
    r.suggestions, #errs > 0 and (" -- " .. table.concat(errs, ", ")) or "")
  return table.concat(out, "\n")
end

return M
