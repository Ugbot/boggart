-- story.lua -- the story layer (lua/story_*.lua): manifests and chapter
-- selection for both layouts, the incremental index, the `story` tool's
-- nouns, the data-only style engine, and the /story views.
-- ctest reuses one HOME per suite, so start from an empty index (before any
-- story.index call, so its schema is recreated fresh). The fixture books are
-- read, never written; `book init` runs on a copy.
for _, t in ipairs{ "sty_books", "sty_files", "sty_fts", "sty_chapters", "sty_entities", "sty_mentions", "sty_payoffs" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local sb, si, ss = require("story.book"), require("story.index"), require("story.style")
local sc, sv = require("story.core"), require("story.view")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function has(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) ~= nil, n .. " -- got: " .. tostring(s)) end
local function hasnt(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) == nil, n .. " -- got: " .. tostring(s)) end
local function iserr(s, n) ok(type(s) == "string" and s:find("^Error:") ~= nil, n .. " -- got: " .. tostring(s)) end

-- a directory no earlier run used (runs can share a second, and nothing here deletes)
local function fresh_dir(tag)
  local base = os.getenv("HOME") .. "/story-" .. tag .. "-" .. tostring(os.time())
  local d, i = base, 0
  while sys.stat(d) do i = i + 1; d = base .. "-" .. i end
  sys.mkdir_p(d)
  return d
end
local FIX = sys.cwd() .. "/tests/fixtures/story"
local S, FL = FIX .. "/structured", FIX .. "/flat"
local function T(a) return sc.call(a) end

-- ---- manifests + chapter selection ---------------------------------------------------
local book = assert(sb.load(S))
ok(book.name == "structured", "a book outside any project is named after its directory")
ok(book.m.manuscript.number == "^(%d+)" and book.m.povs[1] == "vera", "manifest fields load")
local chs = sb.chapters(book)
ok(#chs == 2, "two chapters; the _recovered file is excluded -- got " .. #chs)
ok(chs[1].path == "chapters/01_revised.md" and chs[1].variant == "revised" and chs[1].done,
  "the revised variant is preferred and counts as done")
ok(chs[2].path == "chapters/02.md" and chs[2].variant == "" and not chs[2].done, "a base-only chapter is a draft")
local body = sb.drop_sections(sb.read(S .. "/chapters/01_revised.md"), book.m.drop_sections)
hasnt(body, "Canon flags", "drop_sections cuts the meta section")
local flat = assert(sb.load(FL))
local fch = sb.chapters(flat)
ok(#fch == 2 and fch[1].variant == "draft" and fch[1].variants["slowcut_draft"] ~= nil,
  "flat layout: chapter number mid-name, draft preferred over the slow cut")
iserr(T{ noun = "book", action = "get", book = FIX .. "/nope" }, "a path with no manifest is an error")
iserr(T{ noun = "book", action = "get", book = "no-such-book" }, "an unknown book name is an error")

-- ---- the index -------------------------------------------------------------------------
local st = si.reindex(book, true)
ok(st.chapters == 2 and st.characters == 2 and st.payoffs == 3, string.format(
  "index: 2 chapters, 2 characters, 3 payoffs -- got %d/%d/%d", st.chapters, st.characters, st.payoffs))
ok(st.changed == st.files and st.files == 8, "a rebuild parses every markdown file -- got " .. st.files .. "/" .. st.changed)
local st2 = si.reindex(book, false)
ok(st2.changed == 0 and st2.removed == 0, "an unchanged book reindexes nothing")
local vera
for _, c in ipairs(si.characters(book)) do if c.id == "01-vera" then vera = c end end
local al = vera and require("json").decode(vera.aliases) or {}
ok(table.concat(al, ","):find("Vera") and table.concat(al, ","):find("Counter"), "aliases from the Name line and title parenthetical: " .. table.concat(al, ","))
local moth_al = require("json").decode(si.characters(book)[2].aliases)
ok(moth_al[1] == "Moth", "a sheet with no Name line takes its name from the file")
ok(#si.mentions(book, "02-moth") == 2, "Moth is mentioned in both chapters")
local function aset(t) return "," .. table.concat(t, ",") .. "," end
local qa = aset(si.aliases("Daniel Vale \u{2014} Agent One, principal viewpoint", "no name line", "01-daniel-vale.md"))
ok(qa == ",Daniel,Vale,", "a title gives the name before the dash, not the role words -- got " .. qa)
qa = aset(si.aliases("Commander Petar Vardin", "", "06-x.md"))
ok(qa == ",Petar,Vardin,", "ranks are not names -- got " .. qa)
qa = aset(si.aliases("POV 1 (Fleming)", "- **Name:** Vera (cover) / codename SOLSTICE", "01.md"))
ok(qa == ",Vera,SOLSTICE,", "with a Name line the title parenthetical (an author influence) is ignored -- got " .. qa)
local p = si.payoffs(book)
ok(p[1].title == "The red door key" and p[1].carrier == "Vera" and p[1].span == "span: 1-12", "payoff ledger parsed")
ok(p[3].carrier == "the station" and p[3].span == "", "a payoff with no span")
ok(#si.parse_payoffs("not a ledger\n- bullet") == 0, "non-numbered lines are not payoffs")

-- ---- the tool -------------------------------------------------------------------------------
has(T{ noun = "book", action = "get", book = S }, "Chapters: 2 (1 done)", "book get")
has(T{ noun = "book", action = "get", book = S }, "Payoffs: 3", "book get shows payoffs")
local lay = T{ noun = "book", action = "check_layout", book = S }
has(lay, "chapters/01_revised.md  [(base), revised]  done", "check_layout lists variants")
hasnt(lay, "recovered.md  [", "check_layout keeps excluded files out")
has(T{ noun = "asset", book = S, kind = "payoffs" }, "plot/payoffs.md", "asset list by kind")
has(T{ noun = "asset", action = "list", book = S }, "## character", "asset list groups by kind")
local hits = T{ noun = "search", book = S, query = "red door" }
has(hits, "chapters/01_revised.md:3:", "search returns file:line")
has(hits, "characters/01-vera.md:6:", "search spans the sheets")
has(T{ noun = "search", book = S, query = "counting steps" }, "chapters/01", "search is stemmed (counted/steps)")
has(T{ noun = "search", book = S, query = "zeppelin" }, "No matches", "search with no hits")
iserr(T{ noun = "search", book = S }, "search needs a query")
has(T{ noun = "character", action = "get", book = S, name = "counter" }, "characters/01-vera.md", "character get by alias")
has(T{ noun = "character", action = "list", book = S }, "in chapters: 1 2", "character list with chapters")
iserr(T{ noun = "character", action = "get", book = S, name = "zed" }, "unknown character")
local cl = T{ noun = "chapter", action = "list", book = S }
has(cl, "✓   1  The Red Door", "chapter list: done glyph and title")
has(cl, "of 1000", "chapter list shows the target")
local g = T{ noun = "chapter", action = "get", book = S, n = 1 }
has(g, "did not use it", "chapter get reads the preferred variant")
hasnt(g, "Canon flags", "chapter get drops meta sections")
has(T{ noun = "chapter", action = "get", book = S, n = 1, raw = true }, "Canon flags", "raw keeps them")
hasnt(T{ noun = "chapter", action = "get", book = S, n = 1, variant = "base" }, "humming", "variant=base reads the base file")
iserr(T{ noun = "chapter", action = "get", book = S, n = 9 }, "no such chapter")
has(T{ noun = "chapter", action = "progress", book = S }, "1. The red door key — carrier: Vera", "progress lists payoffs")
iserr(T{ noun = "chapter", action = "fly", book = S }, "unknown action")
iserr(T{ noun = "dragon" }, "unknown noun")

-- ---- style (the older flat style file still loads, as rules) --------------------------------------
local St, src = ss.load(book)
ok(src:find("style.lua$") and St.limits.max_words == 30, "the style file loads as data")
has(T{ noun = "style", action = "get", book = S, bits = "voice" }, "under 30 words", "style get bits= pulls a guide section, limits interpolated")
has(T{ noun = "style", action = "get", book = S, pov = "vera" }, "This POV (vera): Clipped. Counts things.", "style get: the voice card with the POV line")
local chk = T{ noun = "style", action = "check", book = S, n = 2 }
has(chk, "Book.Banned          line 3: 'software' is banned in this book", "banned words with line numbers")
has(chk, "line 3: 'okay' is banned", "every banned word")
has(chk, "refrain 'not today' used 2 times (max 1)", "refrains counted")
has(chk, "VERDICT: FAIL (3 errors", "chapter 2 fails (legacy rules are errors)")
has(T{ noun = "style", action = "check", book = S, n = 1 }, "VERDICT: PASS", "chapter 1 passes")
has(T{ noun = "style", action = "check", book = S, text = "In other words, it was fine." }, "theme tell: 'in other words'", "check raw text")
local long = string.rep("word ", 40) .. "end."
has(T{ noun = "style", action = "check", book = S, text = long }, "sentence of 41 words (max 30)", "the book's own cap, not a baked-in one")
-- data only: a style file cannot reach the environment
local d = fresh_dir("evil")
sys.mkdir_p(d .. "/.boggart")
local f = io.open(d .. "/.boggart/story.json", "w"); f:write('{"title":"evil"}'); f:close()
f = io.open(d .. "/.boggart/style.lua", "w"); f:write('os.exit(3) return {}'); f:close()
local r2, why = ss.load(assert(sb.load(d)))
ok(#r2.base.rules == 0 and tostring(why):find("did not return"), "a style file that calls os is refused: " .. tostring(why))
has(T{ noun = "style", action = "render", book = S }, "# Style", "style render")

-- ---- incremental reindex notices edits ----------------------------------------------------------
f = io.open(d .. "/chapters.md", "w"); f:write("# x\n"); f:close()
sys.mkdir_p(d .. "/chapters")
f = io.open(d .. "/chapters/01.md", "w"); f:write("# One\n\nalpha beta\n"); f:close()
local eb = assert(sb.load(d))
ok(si.reindex(eb, true).chapters == 1, "a new book with one chapter")
f = io.open(d .. "/chapters/02.md", "w"); f:write("# Two\n\ngamma\n"); f:close()
local s3 = si.fresh(eb)
ok(s3.changed == 1 and s3.chapters == 2, "a new chapter file is picked up lazily")
os.remove(d .. "/chapters/02.md")
local s4 = si.fresh(eb)
ok(s4.removed == 1 and s4.chapters == 1, "a deleted chapter file drops out")

-- a revision much shorter than its base is flagged, not trusted
f = io.open(d .. "/chapters/03.md", "w"); f:write("# Three\n\n" .. string.rep("long draft words ", 100) .. "\n"); f:close()
f = io.open(d .. "/chapters/03_revised.md", "w"); f:write("# Three\n\nshort revision.\n"); f:close()
si.fresh(eb)
local nav3 = sv.command("chapters " .. d, 80)
has(nav3, "! revised is SHORTER than the base file (2 vs 300 words)", "a shrunk revision is flagged in the navigator")
has(nav3, "1 chapter(s) read from a variant much shorter", "and counted in the summary")
has(T{ noun = "chapter", action = "list", book = d }, "shorter than its base variant (300 words)", "and in chapter list")
hasnt(sv.command("chapters " .. S, 80), "SHORTER", "a revision that grew is not flagged")
has(T{ noun = "style", action = "check", book = S, text = "He left \u{2014} then came back." }, "line 1: '\u{2014}' is banned",
  "a banned mark with no letters matches anywhere")

-- ---- book init on a copy of the flat fixture ---------------------------------------------------------
local ib = fresh_dir("init")
for _, name in ipairs{ "manuscript_book1_chapter01_draft.md", "manuscript_book1_chapter02_draft.md", "01-world.md" } do
  local src_f = io.open(FL .. "/" .. name, "rb"); local txt = src_f:read("a"); src_f:close()
  local dst = io.open(ib .. "/" .. name, "wb"); dst:write(txt); dst:close()
end
has(T{ noun = "book", action = "init", path = ib, dry_run = true }, "not written", "init dry run")
ok(sys.stat(ib .. "/.boggart/story.json") == nil, "a dry run writes nothing")
local init = T{ noun = "book", action = "init", path = ib }
has(init, "2 chapters", "init proposes a flat manifest that finds the chapters")
iserr(T{ noun = "book", action = "init", path = ib }, "init refuses to overwrite")
has(T{ noun = "book", action = "init", path = S, dry_run = true }, "Error:", "init on a book with a manifest refuses even a dry run")

-- ---- views -----------------------------------------------------------------------------------------
local nav = sv.command("chapters " .. S, 60)
has(nav, "2 chapters: 1 done, 1 in draft", "navigator summary")
has(nav, "✓   1 The Red Door", "navigator row")
for _, w in ipairs{ 40, 60, 100 } do
  local out = sv.command("chapters " .. S, w) .. "\n" .. sv.command("character list book=" .. S, w)
  local widest = 0
  for line in (out .. "\n"):gmatch("(.-)\n") do widest = math.max(widest, sv.fit and require("tracker_view").display_width(line) or #line) end
  ok(widest <= w, "no line wider than " .. w .. " (got " .. widest .. ")")
end
has(sv.command('search book=' .. S .. ' query="red door"', 100), "chapters/01_revised.md:3:", "/story passes quoted key=value")
has(sv.command("help", 80), "/story chapters", "help")
has(sv.command("wat", 80), "story: unknown", "unknown subcommand")
local out, code = require("story.cli").run{ "chapter", "get", "n=9", "book=" .. S }
ok(code == 1 and out:find("^Error:"), "the CLI exits 1 on an error")
out, code = require("story.cli").run{ "chapter", "list", "book=" .. S }
ok(code == 0 and out:find("The Red Door"), "the CLI answers")

-- ---- drafting by expansion (lua/story/draft.lua) --------------------------------------------------
local sd = require("story.draft")
local W = fresh_dir("draft")
os.execute(string.format("cp -R %q/. %q && git -C %q init -q && git -C %q add -A && "
  .. "git -C %q -c user.name=t -c user.email=t@t commit -qm init", S, W, W, W, W))
local function D(a) a.book = W; return sc.call(a) end
local function ch3() return sb.read(W .. "/chapters/03.md") end

iserr(D{ noun = "plan", action = "get", n = 3 }, "no plan yet")
iserr(D{ noun = "plan", action = "set", n = 3 }, "a plan needs beats")
local ps = D{ noun = "plan", action = "set", n = 3, beats = "- Vera opens the red door.\n- Moth pays the price.",
  card = "The door, and what it costs.", title = "The Price", pov = "vera", unit = "line" }
has(ps, "Saved .boggart/plans/ch03.md", "plan set writes the plan into the book")
has(ps, "○ 1. Vera opens the red door.   ← outline next", "a beat with no lines is outlined first")
has(sb.read(W .. "/.boggart/plans/ch03.md"), "target: chapters/03.md", "the target defaults from the manuscript glob")
iserr(D{ noun = "draft", action = "write", n = 3, id = "1.1", text = "x" }, "no writing before the beat is outlined")
local pk = D{ noun = "draft", action = "next", n = 3 }
has(pk, "Break beat 1 into", "next step: outline")
has(pk, "later 2. Moth pays the price.", "later beats are shown so the step does not get ahead")
has(pk, "(end of chapter 2)", "a chapter's first step sees the end of the previous chapter")
hasnt(pk, "is banned", "no ban list in the drafting prompt (named bans can prime)")
hasnt(pk, "okay", "banned words are never named in the drafting prompt")
has(pk, "This POV (vera): Clipped. Counts things.", "the POV voice is in the packet")
has(pk, "Narration: close third person, past tense.", "person and tense are pinned")
ok(pk:find("## Voice", 1, true) == 1, "the voice card comes first")
ok(pk:find("## Task", 1, true) > pk:find("## The manuscript so far", 1, true), "the task comes last, after the manuscript")
has(pk, "### Vera Lind", "the cast named in the beat is in the packet")
has(D{ noun = "plan", action = "expand", n = 3, id = "1", lines = "1. She counts the steps.\n2. The key turns." },
  "2 paragraph line(s) added", "plan expand cleans list markers")
iserr(D{ noun = "draft", action = "write", n = 3, id = "1.2", text = "x" }, "the chapter is written in order")
local w1 = D{ noun = "draft", action = "write", n = 3, id = "1.1", text = "Nine steps. She counted them twice." }
has(w1, "chapter 0 -> 6 words (measured on disk)", "words are measured, not claimed")
has(w1, "Checkpoint: refs/boggart/checkpoints/story/", "each write is checkpointed")
has(ch3(), "# The Price\n\nNine steps.", "the chapter file is created with its title")
local refs = io.popen("git -C " .. W .. " for-each-ref refs/boggart/ --format='%(refname)'"):read("a")
has(refs, "/ch03/b1", "the checkpoint ref exists in the book's repo")
has(io.popen("git -C " .. W .. " status --porcelain --untracked-files=all chapters"):read("a"), "?? chapters/03.md",
  "checkpointing never touches the index or HEAD")
local w2 = D{ noun = "draft", action = "write", n = 3, text = "The software key turned." }
has(w2, "STYLE FAIL: Book.Banned line 1: 'software' is banned", "a paragraph is style-checked as it is written")
has(w2, "Beat 1 complete.", "beat completion is reported")
has(w2, "Next: outline beat 2", "and the next step named")
has(D{ noun = "draft", action = "redo", n = 3, text = "The key turned. The lock gave." }, "Style clean.", "redo replaces the last paragraph")
local t3 = ch3()
ok(not t3:find("software") and t3:find("Nine steps") and t3:find("The lock gave"), "redo kept the earlier paragraph: " .. t3)
iserr(D{ noun = "plan", action = "set", n = 3, beats = "- other" }, "a plan with written paragraphs is not replaced")

-- draft run: fresh bounded model calls, outline then write, in order; a
-- banned word is backtracked (cut at its sentence, continued without it)
local calls = {}
sd.model_impl = function(system, user, opts)
  calls[#calls + 1] = user
  if user:find("Break beat", 1, true) then return "- Moth counts out the scrip.\n- He does not look up.", "end_turn" end
  if #calls == 2 then return "Moth counted the scrip twice, slowly, by the lamp. Then he checked the software ledger.", "end_turn" end
  if user:find("## Continue from here", 1, true) then return "Then he checked the paper ledger.", "end_turn" end
  return "Moth counted the scrip. It was short by one.", "end_turn"
end
local r = D{ noun = "draft", action = "run", n = 3, steps = 5 }
has(r, "step 1: Beat 2: 2 paragraph line(s) added", "run outlines the next beat")
has(r, "backtrack 1: 'software' (Book.Banned)", "a banned word is backtracked during generation")
has(ch3(), "Moth counted the scrip twice, slowly, by the lamp. Then he checked the paper ledger.", "the kept prefix plus the continuation")
has(r, "Chapter plan complete.", "run stops when the plan is written")
has(r, "Plan: beats 2/2, paragraphs 4/4.", "run reports progress")
hasnt(ch3(), "software", "the retried paragraph replaced the bad one")
local maxlen = 0
for _, u in ipairs(calls) do maxlen = math.max(maxlen, #u) end
ok(maxlen <= sd.DEFAULTS.budget + 400, "every step's context is bounded -- got " .. maxlen)
has(calls[#calls], "The manuscript so far", "each step sees the words just written")
has(calls[#calls], "done 1. Vera opens the red door.", "finished beats are the running summary")

-- a truncated answer is never written
D{ noun = "plan", action = "set", n = 4, beats = "- One beat" }
D{ noun = "plan", action = "expand", n = 4, id = "1", lines = "a line" }
sd.model_impl = function() return "cut off mid", "max_tokens" end
has(D{ noun = "draft", action = "run", n = 4, steps = 2 }, "was NOT written", "max_tokens stops the run")
ok(sb.read(W .. "/chapters/04.md") == nil, "and nothing reached the chapter")
-- an existing chapter is not appended to unless the plan says so
D{ noun = "plan", action = "set", n = 2, beats = "- More", target = "chapters/02.md" }
D{ noun = "plan", action = "expand", n = 2, id = "1", lines = "a line" }
has(D{ noun = "draft", action = "write", n = 2, text = "Extra." }, "already exists and this plan did not start it", "no silent append")
D{ noun = "plan", action = "set", n = 2, append = true }
has(D{ noun = "draft", action = "write", n = 2, text = "Extra words here." }, "Wrote 1 to chapters/02.md", "append=true allows it")
has(sb.read(W .. "/chapters/02.md"), "Not today, she had said.\n\nExtra words here.", "appended after the existing text")
-- a small budget trims the low-priority blocks, never the task
D{ noun = "plan", action = "set", n = 5, beats = "- Vera and Moth argue about the red door key." }
local small = D{ noun = "draft", action = "next", n = 5, budget = 1200 }
has(small, "Break beat 1", "the task survives any budget")
ok(small:find("(dropped)", 1, true) or small:find("(trimmed)", 1, true), "and the report says what was cut")
ok(sb.word_count("# A Title\n\none two\n\n---\n\nthree") == 3, "headings and rules are not words")
ok(#sd.clean_lines("```\n- [ ] one\n* two\n3) three\nParagraph 4: four\n```") == 4, "clean_lines strips list noise")
ok(sd.clean_prose("```\n# Heading\nText.\n```") == "Text.", "clean_prose strips fences and headings")
local rt = sd.parse(sd.render(sd.parse(sb.read(W .. "/.boggart/plans/ch03.md"))))
ok(sd.render(rt) == sb.read(W .. "/.boggart/plans/ch03.md"), "plan render/parse round-trips byte for byte")

io.write(string.format("story: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
