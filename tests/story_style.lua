-- story_style.lua -- the style system (docs/story-style.md): the Vale-style
-- checker (types, levels, suppression, allow-list), style SETS (person/tense,
-- per book, per POV, per chapter), exemplars, the baseline and drift, the
-- slop pack and profiler, decode (sampler, backtracking, repair), beat-unit
-- drafting, candidates + picks, and the training-data export.
for _, t in ipairs{ "st_entity", "st_alias", "st_event", "st_delta", "st_fact", "st_knows", "st_promise",
                    "st_exemption", "st_proposal", "st_change", "st_seq", "st_fts",
                    "sty_books", "sty_files", "sty_fts", "sty_chapters", "sty_entities", "sty_mentions", "sty_payoffs" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local lint, ss, bl = require("story.lint"), require("story.style"), require("story.baseline")
local slop, dec, sd = require("story.slop"), require("story.decode"), require("story.draft")
local sb, sc = require("story.book"), require("story.core")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function has(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) ~= nil, n .. " -- got: " .. tostring(s)) end
local function hasnt(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) == nil, n .. " -- got: " .. tostring(s)) end
local function iserr(s, n) ok(type(s) == "string" and s:find("^Error:") ~= nil, n .. " -- got: " .. tostring(s)) end
local function fresh_dir(tag)
  local base = os.getenv("HOME") .. "/sty-" .. tag .. "-" .. tostring(os.time())
  local d, i = base, 0
  while sys.stat(d) do i = i + 1; d = base .. "-" .. i end
  sys.mkdir_p(d)
  return d
end
local function put(path, text)
  sys.mkdir_p(path:match("^(.*)/[^/]+$"))
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

-- ---- the checker ------------------------------------------------------------------------------
local rules = {
  { id = "T.Ban", type = "existence", level = "error", tokens = { "okay", "~not [%a]+, but " }, message = "'{token}'" },
  { id = "T.Swap", type = "substitution", level = "warning", swap = { ["toward"] = "towards" } },
  { id = "T.Budget", type = "occurrence", scope = "text", tokens = { "the way" }, exceptions = { "on the way" }, max = 1,
    level = "warning", message = "'the way' {n} (max {max}; lines {lines})" },
  { id = "T.Opener", type = "repetition", what = "opener", run = 3, level = "warning" },
  { id = "T.Twin", type = "consistency", pairs = { { "Kolya", "Kolia" } }, level = "error" },
  { id = "T.Cond", type = "conditional", first = "revolver", second = "fired", level = "suggestion" },
  { id = "T.Long", type = "metric", metric = "sentence_max", max = 12, level = "warning" },
}
local text = table.concat({
  "Okay, she said. It was not grief, but fear.",
  "He walked toward the door the way a man walks to a grave, on the way home.",
  "She waited. She counted. She left. The way was long.",
  "Kolya had the revolver. Kolia did not.",
  "<!-- style off: T.Long -->",
  "This is a very long sentence that keeps going and going far past the twelve word cap set above.",
  "<!-- style on -->",
  "This is another very long sentence that keeps going and going far past the twelve word cap.",
}, "\n")
local r = lint.check(text, rules, { label = "t" })
has(r.report, "ERROR   T.Ban                line 1: 'okay'", "existence, located")
has(r.report, "line 1: '~not [%a]+, but '", "a raw-pattern token (not X, but Y)")
has(r.report, "T.Swap               line 2: 'toward' -> prefer 'towards'", "substitution")
has(r.report, "'the way' 2 (max 1; lines 2, 3)", "occurrence: an exception ('on the way') does not count")
has(r.report, "3 sentences in a row open with 'she'", "repetition: opener runs")
has(r.report, "both 'Kolya' (1) and 'Kolia' (1)", "consistency")
has(r.report, "'revolver' without 'fired'", "conditional")
has(r.report, "line 8: sentence of 17 words (max 12)", "metric")
hasnt(r.report, "line 6: sentence", "a suppressed span is not reported")
has(r.report, "suppressed in the text: T.Long x1", "but the suppression is listed")
ok(r.verdict == "FAIL" and r.errors == 3, "only errors fail: " .. r.errors)
local r2 = lint.check("She waited. She counted. She left.", rules, { allow = { "T.Opener" } })
has(r2.report, "note    T.Opener", "an allowed device drops to a note")
has(r2.report, "(allowed device)", "and says why")
ok(r2.verdict == "PASS", "and does not fail")
ok(#lint.check("He said: fine.", { { id = "X", type = "existence", level = "error", tokens = { "\u{201C}" } } }).findings == 0,
  "a multi-byte mark is matched as a string")

-- person and tense (narration only: dialogue is ignored)
local third = string.rep("She walked to the door and opened it. The hall was dark and she was tired. ", 12)
local first = string.rep("I walked to the door and opened it. The hall was dark and I was tired. ", 12)
local present = string.rep("She walks to the door and opens it. The hall is dark and she is tired and she knows it. ", 12)
local dialogue = string.rep("She said, \"I am here and I know what I am doing, I am.\" The hall was dark. ", 12)
local P3 = { { id = "Set.Person", type = "metric", metric = "person", person = "third", level = "warning" } }
local T3 = { { id = "Set.Tense", type = "metric", metric = "tense", tense = "past", level = "warning" } }
ok(#lint.check(third, P3).findings == 0, "third person passes a third-person check")
has(lint.check(first, P3).report, "first-person narration", "first person is caught in a third-person set")
ok(#lint.check(dialogue, P3).findings == 0, "an 'I' in dialogue is not narration")
has(lint.check(present, T3).report, "drifts out of past tense", "present tense is caught in a past set")
ok(#lint.check(third, T3).findings == 0, "past tense passes")

-- ---- a book with sets ---------------------------------------------------------------------------
local B = fresh_dir("book")
put(B .. "/.boggart/story.json", [[{"title":"Sets","manuscript":{"glob":["chapters/*.md"],"number":"^(%d+)","prefer":[""],"done":[""]},
  "characters":["characters/*.md"],"narration":"close third person, past tense"}]])
put(B .. "/.boggart/style.lua", [[
return {
  voice = { "Cold, precise, worn.", "Grief lives under the words." },
  pov = { vera = "time-stamped, procedural", moth = "dry, fast, money has a number" },
  rules = {
    { id = "Book.Banned", type = "existence", level = "error", tokens = { "software", "okay" }, guide = "ban_list" },
    { id = "Book.OpenerRun", type = "repetition", what = "opener", run = 3, level = "warning" },
  },
  allow = { "Book.OpenerRun" },
  default_set = "third-past",
  pov_sets = { moth = "moth-first" },
  sets = {
    ["moth-first"] = { extends = "first-past", voice = { "Moth talks to you like a debtor." }, exemplar_set = "moth",
                       rules = { { id = "Book.Banned", level = "warning" } } },
  },
  decode = { min_p = 0.03, dry_multiplier = 0.8 },
  guide = { order = { "ban_list", "voice" }, bits = { ban_list = "## Bans\nNo modern words.", voice = "## Voice\nCold." } },
}
]])
put(B .. "/.boggart/style/exemplars/vera-archive.md", "---\npov: vera\nmode: interior\ngolden: true\n---\n"
  .. string.rep("At 21:07 the music changed. Vera filed the card and waited for the stamp. ", 30))
put(B .. "/.boggart/style/exemplars/moth-dock.md", "pov: moth\nset: moth\n\n"
  .. string.rep("I owed the Guild nine hundred and I knew the number to the coin. ", 30))
put(B .. "/.boggart/style/exemplars/any-talk.md", "mode: dialogue\n\n"
  .. string.rep("\"Well,\" said Kolya. \"We'll see.\" ", 40))
local bk = assert(sb.load(B))
local S = ss.load(bk)
local E = assert(ss.resolve(S, {}))
ok(E.name == "third-past" and E.narration:find("close third person, past tense", 1, true), "the default set is a library set")
ok(E.voice[#E.voice] == "Grief lives under the words.", "the book's voice follows the library's generic line")
local Em = assert(ss.resolve(S, { pov = "moth" }))
ok(Em.name == "moth-first" and Em.narration:find("^first person, past"), "a POV maps to its own set, which extends first-past")
ok(Em.voice[#Em.voice] == "Moth talks to you like a debtor.", "the book's set is the most specific layer")
local lv
for _, rr in ipairs(Em.rules) do if rr.id == "Book.Banned" then lv = rr.level end end
ok(lv == "warning", "a set overrides a rule's level by id")
local person_rule
for _, rr in ipairs(Em.rules) do if rr.id == "Set.Person" then person_rule = rr.person end end
ok(person_rule == "first", "and inherits the library's person check")
ok(select(2, ss.resolve(S, { set = "no-such" })):find("no style set 'no-such'", 1, true), "an unknown set says where it looked")
-- a user library set in ~/.boggart/style/sets wins over the built-in of the same name
put(os.getenv("HOME") .. "/.boggart/style/sets/third-past.lua", 'return { narration = "USER third past", rules = {} }')
ok(assert(ss.resolve(ss.load(bk), {})).narration == "USER third past", "a user library set is found before the built-in")
os.remove(os.getenv("HOME") .. "/.boggart/style/sets/third-past.lua")

-- exemplars: per POV, per set, golden first, varied modes
local ev = ss.pick(E, { pov = "vera", k = 3 })
ok(ev[1] and ev[1].id == "vera-archive", "golden first")
local ids = {}
for _, x in ipairs(ev) do ids[x.id] = true end
ok(not ids["moth-dock"], "a set's exemplars stay in their set")
ok(ids["any-talk"], "unassigned exemplars are shared")
local em = ss.pick(Em, { pov = "moth", k = 3 })
ids = {}
for _, x in ipairs(em) do ids[x.id] = true end
ok(ids["moth-dock"] and not ids["vera-archive"], "Moth's set gets Moth's passages, not Vera's")
ok(ss.mode_of("\"Well,\" said Kolya. \"We'll see.\" \"Yes.\"") == "dialogue", "mode: dialogue")
ok(ss.mode_of("Vera argues with Moth about the key", true) == "dialogue", "brief mode from its verbs")

-- checking in a set; guide sections for failures
local cv = ss.check(bk, "It was okay. " .. third, {})
has(cv.report, "ERROR   Book.Banned", "the base book's bans are errors")
local cm = ss.check(bk, "It was okay. " .. third, { pov = "moth" })
has(cm.report, "warning Book.Banned", "in Moth's set the same ban is a warning")
has(cm.report, "Set.Person", "and third-person narration is flagged in a first-person set")
has(ss.guide_for(S, E, cv.findings), "No modern words.", "a failed rule hands over its guide section, only that")
hasnt(ss.guide_for(S, E, cv.findings), "## Voice", "not the whole guide")
has(sc.call{ noun = "style", action = "sets", book = B, set = "moth-first" }, "moth-first: first-past (built-in) -> moth-first (book)",
  "style sets shows the chain")
has(sc.call{ noun = "style", action = "get", book = B, pov = "moth" }, "Narration: first person, past tense", "style get shows the POV's set")

-- ---- baseline + drift -----------------------------------------------------------------------------
local author = {
  "I didn't know. We'd waited, and it wasn't the first time we'd lost. My hands were cold; I counted them anyway. It's a habit. "
    .. "He said it'd pass. It didn't. We sat in the kitchen and I made tea because that's what you do. " .. string.rep("I'm tired, and we're late. ", 14),
  "We'd gone down to the dock. I couldn't see the boat, and it wasn't there when we looked again. My father's coat was wet. "
    .. "I didn't say anything. You don't, at the dock. " .. string.rep("It's late and I'm cold, and we don't talk. ", 12),
  "It wasn't grief. I'd have known grief. My mother's voice on the phone, and then nothing, and then I'd hung up. "
    .. "We don't call back. We never have. " .. string.rep("I can't, and I won't, and it doesn't matter. ", 12),
}
local Bl = assert(bl.build(author))
local same = bl.drift(author[1], Bl)
ok(#same.flagged == 0, "the author's own text is within range")
local flattened = "The individual had not been aware. Subsequently, the circumstances deteriorated considerably; nevertheless, "
  .. "the protagonist maintained composure: a remarkable demonstration of resilience. " ..
  string.rep("The situation was undeniably complex, multifaceted, and profoundly consequential for everyone involved. ", 6)
local d = bl.drift(flattened, Bl)
ok(d.normalization >= 1.5, "prose moved the way AI revision moves it scores as flattened: " .. string.format("%.2f", d.normalization))
has(bl.report(d, "x"), "FLATTENED", "and says so")
local found_contr = false
for _, m in ipairs(d.flagged) do if m.key == "contractions" then found_contr = true end end
ok(found_contr, "the lost contractions are named")
local sh = bl.edit_shift(author[1], flattened)
ok(sh and sh.normalization >= 1, "an edit is measured against what it replaced")
bl.save(B, Bl)
ok(bl.load(B).markers.contractions.mean > 0, "the baseline is stored in the book")
has(sc.call{ noun = "style", action = "drift", book = B, text = flattened }, "AI-normalization score", "style drift")

-- ---- slop -------------------------------------------------------------------------------------------
has(lint.check("A tapestry of light. It wasn't grief. It was fear.", slop.rules(bk)).report, "AI tell: 'tapestry'", "the pack")
local drafts = { string.rep("His jaw tightened and the silence hung between them. ", 5), string.rep("Her jaw tightened. ", 4) }
local over = slop.overrep(drafts, author, { ratio = 5 })
local grams = {}
for _, g in ipairs(over) do grams[#grams + 1] = g.gram end
has(table.concat(grams, "|"), "jaw tightened", "the profiler finds what the drafts over-use against the author")
hasnt(table.concat(grams, "|"), "|and the|", "function-word grams are not proposed")
-- scan -> proposals -> accept -> the ban is live
sd.append_jsonl(B .. "/" .. sd.GENERATED, { chapter = 1, id = "1", text = drafts[1] })
sd.append_jsonl(B .. "/" .. sd.GENERATED, { chapter = 1, id = "2", text = drafts[2] })
put(B .. "/chapters/01.md", "# One\n\n" .. table.concat(author, "\n\n") .. "\n\n" .. table.concat(author, "\n\n")
  .. "\n\n" .. table.concat(author, "\n\n") .. "\n\n" .. table.concat(author, "\n\n") .. "\n")
local scan = sc.call{ noun = "style", action = "slop", book = B }
has(scan, "'jaw tightened'", "style slop reports it")
has(scan, "proposal accept group=slop", "and proposes bans")
local sm = require("story.model")
local q = sm.select_proposals(bk.name, { group = "slop" })
ok(#q >= 1, "proposals are queued for the author")
local acc = sc.call{ noun = "proposal", action = "accept", book = B, group = "slop", _author = true }
has(acc, "accepted", "the author accepts")
has(lint.check("His jaw tightened.", slop.rules(bk)).report, "over-used by the model in this book: 'jaw tightened'", "the accepted ban is live")
has(sc.call{ noun = "style", action = "ban", book = B, phrase = "a beat passed" }, "Proposed", "the model's ban is a proposal")
has(sc.call{ noun = "style", action = "ban", book = B, phrase = "a beat passed", level = "error", _author = true }, "Banned 'a beat passed' (error)",
  "the author's ban is immediate")

-- ---- decode ----------------------------------------------------------------------------------------
local brules = ss.rules(E, bk)
local sl = dec.sampler(E, { url = "http://localhost:8080/v1", wire = "openai" }, brules)
ok(sl and sl.min_p == 0.03 and sl.dry_multiplier == 0.8, "a local route gets the book's sampler settings")
local bias = {}
for _, pr in ipairs(sl.logit_bias or {}) do bias[pr[1]] = pr[2] end
ok(bias[" software"] == false and bias["okay"] == false, "and a logit_bias forbidding the error-level single-word bans")
ok(dec.sampler(E, { url = "https://api.anthropic.com", wire = "anthropic" }, brules) == nil, "an API route gets none")
local api = require("api")
local ob = api._body_for_wire("openai", { model = "m", messages = { { role = "user", content = "x" } }, sampler = sl })
ok(ob.min_p == 0.03 and ob.logit_bias, "the OpenAI wire forwards the sampler")
local ab = api._body_for_wire("anthropic", { model = "m", messages = { { role = "user", content = "x" } }, sampler = sl })
ok(ab.sampler == nil and ab.min_p == nil, "the Anthropic wire strips it")
-- backtracking and repair with a fake model
local seen = {}
local function fake(user)
  seen[#seen + 1] = user
  if #seen == 1 then return "The ledger was long and dull, and Vera read it twice by lamplight. Then the software failed.", "end_turn" end
  return "Then the lamp failed.", "end_turn"
end
local out, log = dec.generate(fake, "brief", brules)
ok(out == "The ledger was long and dull, and Vera read it twice by lamplight. Then the lamp failed.", "backtrack keeps the prefix: " .. out)
has(seen[2], "Do not use the words or phrases: software", "the continuation is told what to avoid")
has(log[1], "backtrack 1: 'software'", "and it is logged")
local bad = "Fine first paragraph here.\nIt was okay, really."
local res = ss.check(bk, bad, {})
local fixed, rlog = dec.repair(function(u) return "It was fine, really." end, bad, res, function(fs) return ss.guide_for(S, E, fs) end)
ok(fixed == "Fine first paragraph here.\nIt was fine, really.", "repair rewrites only the failing paragraph: " .. fixed)
has(rlog[1], "repaired line 2", "and says which")

-- ---- beat-unit drafting, candidates, picks, dataset ----------------------------------------------------------
os.execute(string.format("git -C %q init -q", B))
local function D(a) a.book = B; return sc.call(a) end
D{ noun = "plan", action = "set", n = 2, beats = "- Vera files the card.\n- Moth pays.", title = "Two", pov = "vera" }
D{ noun = "plan", action = "expand", n = 2, id = "1", lines = "She reads it.\nShe stamps it.\nShe files it." }
local pk = D{ noun = "draft", action = "next", n = 2 }
has(pk, "Continue the manuscript with beat 1: 3 paragraphs", "a beat is one call covering its lines")
has(pk, "How this book is written", "exemplars are in the packet")
has(pk, "At 21:07 the music changed", "the author's own passage")
hasnt(pk, "I owed the Guild", "another set's passage is not")
hasnt(pk, "okay", "no bans in the prompt")
local wb = D{ noun = "draft", action = "write", n = 2, id = "1", text = "She read it.\n\nShe stamped it.\n\nShe filed it." }
has(wb, "Wrote 1 to chapters/02.md", "a beat is written in one step")
has(D{ noun = "plan", action = "get", n = 2 }, "✓ 1. Vera files the card.", "and all its lines are done")
-- candidates: rank, the author picks, the pick is logged
D{ noun = "plan", action = "expand", n = 2, id = "2", lines = "Moth counts the scrip." }
local k = 0
sd.model_impl = function(system, user)
  k = k + 1
  if user:find("Rate the prose", 1, true) then return "7", "end_turn" end
  if k == 1 then return "It was okay. Moth counted.", "end_turn" end
  return "Moth counted the scrip, twice, and it was short by one.", "end_turn"
end
local cands = D{ noun = "draft", action = "candidates", n = 2, k = 2 }
has(cands, "2 candidates for 2 (best first)", "candidates are ranked")
ok(cands:find("%[1%] score [%d%.]+%s+%(0 errors") ~= nil, "the clean one ranks first: " .. cands)
has(D{ noun = "draft", action = "pick", n = 2, c = 1, _author = true }, "Wrote 2", "the pick is written")
local prefs = sb.read(B .. "/.boggart/style/prefs.jsonl") or ""
has(prefs, '"kind":"pick"', "and logged as the author's preference")
has(prefs, '"chosen":"Moth counted the scrip, twice, and it was short by one."', "with what was chosen")
has(D{ noun = "draft", action = "redo", n = 2, text = "Moth counted the scrip twice. Short by one.", _author = true }, "Rewrote 2", "an author redo")
has(sb.read(B .. "/.boggart/style/prefs.jsonl"), '"kind":"edit"', "is logged as an edit")
has(D{ noun = "style", action = "prefs" }, "edit 1, pick 1", "style prefs summarises them")
-- dataset for a local LoRA
local ds = D{ noun = "style", action = "dataset" }
has(ds, "continuation examples", "a dataset from the author's prose")
local tr = sb.read(B .. "/.boggart/style/train/train.jsonl") or ""
has(tr, '"role":"assistant"', "in chat format")
has(sb.read(B .. "/.boggart/style/train/preferences.jsonl") or "", '"rejected"', "with preference pairs")
has(D{ noun = "style", action = "finetune" }, "adapter:", "finetune says what it would run")
iserr(D{ noun = "style", action = "finetune", run = true }, "only the author starts training")

io.write(string.format("story_style: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
