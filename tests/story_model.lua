-- story/model.lua -- the story model (lua/story/model.lua, lua/story/world.lua):
-- alias resolution before insert, event-sourced state as of story time,
-- facts with status / modality / withholding, knowledge for characters (t) and
-- the reader (pos), retcons, proposals (the model proposes, the author
-- decides), and the committed JSONL mirror.
-- ctest reuses HOME per suite: start from empty st_* tables.
for _, t in ipairs{ "st_entity", "st_alias", "st_event", "st_delta", "st_fact", "st_knows", "st_promise",
                    "st_exemption", "st_proposal", "st_change", "st_seq", "st_fts" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local sm, sc, sv = require("story.model"), require("story.core"), require("story.view")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function has(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) ~= nil, n .. " -- got: " .. tostring(s)) end
local function hasnt(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) == nil, n .. " -- got: " .. tostring(s)) end
local function iserr(s, n) ok(type(s) == "string" and s:find("^Error:") ~= nil, n .. " -- got: " .. tostring(s)) end

local function fresh_dir(tag)
  local base = os.getenv("HOME") .. "/stm-" .. tag .. "-" .. tostring(os.time())
  local d, i = base, 0
  while sys.stat(d) do i = i + 1; d = base .. "-" .. i end
  sys.mkdir_p(d .. "/.boggart")
  return d
end
local B = fresh_dir("book")
local f = io.open(B .. "/.boggart/story.json", "w"); f:write('{"title":"Model Test"}'); f:close()
f = io.open(B .. "/notes.md", "w"); f:write("# Notes\n\nVera keeps the brass key in her coat.\nMoth owes the Guild money.\n"); f:close()
local book = require("story.book").load(B).name

-- author = typed at /story (canon); model = the tool (proposals)
local function A(a) a.book = B; a._author = true; return sc.call(a) end
local function Mdl(a) a.book = B; return sc.tool.run(a) end

-- ---- entities + aliases (resolution before insert) ------------------------------------------------
has(A{ noun = "entity", action = "add", kind = "character", name = "Vera Lind", aliases = "Vera, The Counter" },
  "entity added: vera-lind", "entity add")
has(A{ noun = "entity", action = "add", kind = "character", name = "Moth", aliases = "Pavel Sorokin" }, "added: moth", "second")
has(A{ noun = "entity", action = "add", kind = "place", name = "Titan Station" }, "added: titan-station", "a place")
has(A{ noun = "entity", action = "add", kind = "place", name = "The Archive", parent = "Titan Station" }, "added: archive", "place in place")
has(A{ noun = "entity", action = "add", kind = "item", name = "Brass Key", aliases = "the key" }, "added: brass-key", "an item")
iserr(A{ noun = "entity", action = "add", kind = "character", name = "Vera" }, "an alias of an existing character is refused")
has(A{ noun = "entity", action = "add", kind = "character", name = "Vera", distinct = true, aliases = "" }, "added: vera-2",
  "distinct=true allows two people to share a name")
local amb = A{ noun = "entity", action = "resolve", name = "vera" }
ok(amb:find("vera-2", 1, true) and amb:find("vera-lind", 1, true), "the shared name lists both people -- got " .. amb)
iserr(A{ noun = "event", action = "add", t = 1, summary = "x", deltas = "Vera status=calm" }, "an ambiguous name in a delta is refused")
has(A{ noun = "entity", action = "resolve", name = "the counter" }, "vera-lind", "aliases match case- and article-insensitively")
ok(sm.norm("Vera’s") == "vera" and sm.norm("  The  Red-Door ") == "red door", "norm: curly possessive, article, punctuation")
-- HPMOR: one Harry, three names
A{ noun = "entity", action = "add", kind = "character", name = "Harry James Potter-Evans-Verres", aliases = "Harry, Harry Potter" }
iserr(A{ noun = "entity", action = "add", kind = "character", name = "Harry Potter" }, "the three-Harrys failure cannot happen")
has(A{ noun = "entity", action = "alias", name = "harry", alias = "Mr Potter" }, "alias", "a new name goes on the one entity")

-- ---- events: state as of story time --------------------------------------------------------------------
has(A{ noun = "event", action = "add", t = 1, summary = "Vera arrives", deltas = "move vera-lind to titan-station; vera-lind status=calm; relate vera-lind moth trust +2" },
  "event added: E1", "event with deltas")
has(A{ noun = "event", action = "add", t = 2, summary = "Vera takes the key", deltas = "vera-lind acquires the key" }, "E2", "acquire by alias")
local w = A{ noun = "event", action = "add", t = 3, summary = "Moth grabs the key", deltas = "moth acquires brass-key; vera-lind status=wounded; relate vera-lind moth trust -1" }
has(w, "WARNING: brass-key is held by vera-lind", "taking an item someone holds warns")
A{ noun = "event", action = "add", t = 4, summary = "Moth dies", deltas = "end moth" }
has(A{ noun = "event", action = "add", t = 5, summary = "Moth walks", deltas = "move moth to archive" }, "WARNING: moth has ended", "a dead man moving warns")
iserr(A{ noun = "event", action = "add", t = 6, deltas = "vera-lind flies" }, "an unreadable delta is refused")
iserr(A{ noun = "event", action = "add", summary = "no time" }, "an event needs t=")
local s1 = sm.state(book, "vera-lind", 1.5)
ok(s1.place == "titan-station" and s1.fields.status == "calm" and #s1.items == 0, "state as of t=1.5")
local s2 = sm.state(book, "vera-lind", 2.5)
ok(s2.holds["brass-key"] and s2.fields.status == "calm", "as of t=2.5 Vera holds the key")
local s5 = sm.state(book, "vera-lind", 9)
ok(s5.fields.status == "wounded" and s5.relations.moth.trust == 1, "later values win, earlier ones stay in history (no lost update)")
local calm = 0
for _, h in ipairs(s5.history) do if h.field == "status" then calm = calm + 1 end end
ok(calm == 2, "both status changes are in the history")
ok(sm.state(book, "moth", 9).relations["vera-lind"].trust == 1, "relations read from both sides")
ok(sm.state(book, "moth", 4.5).ended == 4, "moth ended at t=4")
ok(sm.holder(book, "brass-key", 2.5) == "vera-lind", "holder as of t")
ok(table.concat(sm.present(book, "titan-station", 2), ",") == "vera-lind", "who is where")
local g = A{ noun = "entity", action = "get", name = "the counter", as_of = 2.5 }
has(g, "at: titan-station", "entity get: place")
has(g, "holds: brass-key", "entity get: holdings as of t")
has(g, "relations: moth (trust 2)", "entity get: relations as of t")
has(A{ noun = "entity", action = "get", name = "brass-key", as_of = 2.5 }, "held by: vera-lind", "item holder")

-- ---- facts: status, modality, withholding --------------------------------------------------------------
has(A{ noun = "fact", action = "add", body = "The brass key opens the red door.", subject = "brass-key", visibility = "secret" },
  "fact added: F1", "a secret fact")
has(A{ noun = "fact", action = "add", body = "Vera is the Guild's agent.", subject = "vera-lind", visibility = "secret", withhold_until = 10 },
  "F2", "a withheld twist")
iserr(A{ noun = "fact", action = "add", body = "The debt is paid.", modality = "claimed" }, "a claim needs a holder")
has(A{ noun = "fact", action = "add", body = "The debt is paid.", modality = "claimed", holder = "moth" }, "F3", "a claim with its claimant")
A{ noun = "fact", action = "add", body = "The station is on Titan.", subject = "titan-station", valid_from = 0, valid_to = 8 }
local ids = {}
for _, x in ipairs(sm.facts_at(book, 5, { pos = 5 })) do ids[x.id] = true end
ok(ids.F1 and not ids.F2 and ids.F4, "withheld facts stay out of a packet before their position")
ids = {}
for _, x in ipairs(sm.facts_at(book, 9, { pos = 12 })) do ids[x.id] = true end
ok(ids.F2 and not ids.F4, "after its position the twist is in; a fact past its validity is out")
has(A{ noun = "fact", action = "list", status = "canon" }, "/claimed by moth", "fact list shows the modality")

-- ---- knowledge: characters at t, the reader at pos --------------------------------------------------------
has(A{ noun = "knows", action = "add", holder = "moth", fact = "F1", t = 3, how = "told", from = "the counter" }, "knows added: K1", "Moth is told at t=3")
has(A{ noun = "knows", action = "add", holder = "reader", fact = "F1", pos = 7 }, "K2", "the reader learns at pos 7")
iserr(A{ noun = "knows", action = "add", holder = "reader", fact = "F1", t = 7 }, "the reader learns at a position, not a time")
iserr(A{ noun = "knows", action = "add", holder = "moth", fact = "F99", t = 1 }, "unknown fact")
A{ noun = "knows", action = "add", holder = "vera-lind", fact = "F3", t = 2, how = "told", from = "moth", version = "Moth says he paid the Guild in full." }
local unk = A{ noun = "knows", action = "what", holder = "moth", as_of = 2 }
has(unk, "does NOT yet know:\n  F1", "before t=3 Moth does not know the secret: the leak guard")
has(A{ noun = "knows", action = "what", holder = "moth", as_of = 3 }, "F1 The brass key opens", "from t=3 he does")
has(A{ noun = "knows", action = "what", holder = "reader", pos = 6 }, "nothing recorded", "the reader's clock is the telling")
has(A{ noun = "knows", action = "what", holder = "vera", as_of = 5 }, "could mean", "holder names resolve like everything else")
has(A{ noun = "knows", action = "what", holder = "vera-lind", as_of = 5 }, "Moth says he paid the Guild in full.  (true: The debt is paid.)",
  "a character's own version is kept beside the fact")
local who = A{ noun = "fact", action = "get", id = "f1" }
has(who, "moth since t=3 (told by vera-lind)", "who knows, since when, from whom")
has(who, "reader since pos 7", "including the reader")

-- ---- retcon ------------------------------------------------------------------------------------------------
has(A{ noun = "fact", action = "retcon", id = "F1", body = "The brass key opens the archive vault." }, "retcon: F5", "retcon makes a new fact")
local old = sm.fact(book, "F1")
ok(old.status == "retconned" and old.superseded_by == "F5", "the old fact is kept, marked and linked")
ids = {}
for _, x in ipairs(sm.facts_at(book, 9)) do ids[x.id] = true end
ok(ids.F5 and not ids.F1, "only the new one is in force")
iserr(A{ noun = "fact", action = "retcon", id = "F1", body = "again" }, "a retconned fact cannot be retconned twice")

-- ---- proposals: the model proposes, the author decides ---------------------------------------------------------
local p1 = Mdl{ noun = "fact", action = "add", body = "Moth hums when nervous.", subject = "moth", group = "ch02" }
has(p1, "Proposed Q1", "a model write is a proposal")
ok(#sm.facts_at(book, 9, { subject = "moth" }) == 0, "and canon is unchanged")
local p2 = Mdl{ noun = "event", action = "add", t = 7, summary = "Vera reaches the archive", deltas = "move vera-lind to archive", group = "ch02" }
has(p2, "Proposed Q2", "events are proposed too")
iserr(Mdl{ noun = "event", action = "add", t = 7, deltas = "move nobody to archive" }, "a proposal naming an unknown entity is refused up front")
local p3 = Mdl{ noun = "entity", action = "add", kind = "character", name = "Irina", group = "ch03",
  evidence_path = "notes.md", evidence_line = 3, quote = "Irina runs the station" }
iserr(p3, "evidence that is not in the file refuses the proposal")
has(Mdl{ noun = "entity", action = "add", kind = "character", name = "The Guild Clerk", group = "ch03",
  evidence_path = "notes.md", evidence_line = 4, quote = "Moth owes the  Guild money." }, "Proposed Q3", "evidence found (whitespace-insensitive)")
has(Mdl{ noun = "fact", action = "add", body = "x", _author = true }, "Proposed", "the model cannot claim to be the author")
iserr(Mdl{ noun = "proposal", action = "accept", all = true }, "the model cannot accept proposals")
local pl = A{ noun = "proposal", action = "list" }
has(pl, "## ch02 / event", "proposals grouped by group then kind")
has(pl, "evidence notes.md:4", "with their evidence")
has(A{ noun = "proposal", action = "accept", group = "ch02" }, "Q1: accepted -> F6", "accept a whole group")
ok(#sm.facts_at(book, 9, { subject = "moth" }) == 1 and sm.state(book, "vera-lind", 7).place == "archive", "accepted proposals are canon")
has(A{ noun = "proposal", action = "reject", ids = "Q3", reason = "not a character" }, "Q3: rejected", "reject by id")
has(A{ noun = "proposal", action = "accept", ids = "Q3" }, "already rejected", "a decided proposal stays decided")
has(A{ noun = "proposal", action = "list", status = "rejected" }, "not a character", "rejections keep their reason")

-- ---- promises, exemptions, lore search ------------------------------------------------------------------------
has(A{ noun = "promise", action = "add", kind = "chekhov", body = "The brass key", due_pos = 20 }, "P1", "a Chekhov item")
has(A{ noun = "promise", action = "list" }, "P1 [chekhov] The brass key  due by pos 20", "open promises")
A{ noun = "promise", action = "pay", id = "P1", payoff = "E9" }
has(A{ noun = "promise", action = "list", status = "paid" }, "paid by E9", "paid promises")
has(A{ noun = "exemption", action = "add", kind = "leak", target = "ch05", reason = "unreliable narrator" }, "X1", "an exemption")
has(A{ noun = "lore", query = "vault" }, "F5", "lore search finds facts (BM25)")
has(A{ noun = "lore", query = "counter" }, "vera-lind", "and entities by alias")

-- ---- the mirror: in the book, canonical, and it survives a wiped store -------------------------------------------
ok(sys.stat(B .. "/.boggart/story/facts.jsonl") == "file", "the mirror is written into the book")
local function snapshot()
  local out = {}
  for _, m in ipairs(sm.MIRROR) do out[#out + 1] = require("story.book").read(B .. "/.boggart/story/" .. m.file .. ".jsonl") or "" end
  return table.concat(out, "\n--\n")
end
local before = snapshot()
sm.import(book, B)
sm.export(book, B)
ok(snapshot() == before, "export -> import -> export is byte-identical")
ok(not before:find('"book"', 1, true), "the mirror carries no store-only columns")
sm.drop_book(book)
bog.store.kv_del("story.mirror." .. book)
ok(sm.state(book, "vera-lind", 9).place == nil, "the store is empty")
has(A{ noun = "entity", action = "get", name = "the counter", as_of = 7 }, "at: archive", "the next read restores the model from the mirror")
ok(snapshot() == before, "and the mirror is untouched by the restore")
-- a hand edit (or git pull) of the mirror wins over the store
local fl = require("story.book").read(B .. "/.boggart/story/facts.jsonl")
f = io.open(B .. "/.boggart/story/facts.jsonl", "w"); f:write((fl:gsub("Moth hums when nervous%.", "Moth whistles when nervous."))); f:close()
has(A{ noun = "fact", action = "list", subject = "moth" }, "whistles", "an edited mirror is re-imported")

-- ---- the TUI / CLI path is the author -------------------------------------------------------------------------
has(sv.command("model status book=" .. B, 100), "entities", "/story model status")
has(sv.command('fact add book=' .. B .. ' body="Titan has no sky." subject=titan-station', 100), "fact added", "/story writes are canon")
local out, code = require("story.cli").run{ "fact", "get", "id=F99", "book=" .. B }
ok(code == 1 and out:find("^Error"), "CLI exit 1 on error")

io.write(string.format("story_model: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
