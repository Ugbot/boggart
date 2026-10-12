-- story/geo.lua -- the world lookups (lua/story/geo.lua + geotool.lua): where
-- things are, containment through the place tree, claim checks, travel against
-- declared routes, and the world audit. A small invented world; no model.
for _, t in ipairs{ "st_entity", "st_alias", "st_event", "st_delta", "st_fact", "st_knows", "st_promise",
                    "st_exemption", "st_proposal", "st_change", "st_seq", "st_fts" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local sm, sc, geo = require("story.model"), require("story.core"), require("story.geo")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function has(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) ~= nil, n .. " -- got: " .. tostring(s)) end
local function hasnt(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) == nil, n .. " -- got: " .. tostring(s)) end
local function iserr(s, n) ok(type(s) == "string" and s:find("^Error:") ~= nil, n .. " -- got: " .. tostring(s)) end

local function fresh_dir(tag)
  local base = os.getenv("HOME") .. "/stg-" .. tag .. "-" .. tostring(os.time())
  local d, i = base, 0
  while sys.stat(d) do i = i + 1; d = base .. "-" .. i end
  sys.mkdir_p(d .. "/.boggart")
  return d
end
local B = fresh_dir("book")
local f = io.open(B .. "/.boggart/story.json", "w"); f:write('{"title":"Geo Test"}'); f:close()
local book = require("story.book").load(B).name
local function A(a) a.book = B; a._author = true; return sc.call(a) end
local function Mdl(a) a.book = B; return sc.tool.run(a) end

-- ---- a world: Europe > France > Paris > Cafe Lune; Europe > Italy > Rome; an island apart ----
local function place(name, parent, aliases) return A{ noun = "entity", action = "add", kind = "place", name = name, parent = parent, aliases = aliases } end
place("Europe"); place("France", "Europe"); place("Paris", "France"); place("Cafe Lune", "Paris", "the cafe")
place("Italy", "Europe"); place("Rome", "Italy"); place("Lyon", "France"); place("Isle of Mist")
A{ noun = "entity", action = "add", kind = "character", name = "Vera Lind", aliases = "Vera" }
A{ noun = "entity", action = "add", kind = "character", name = "Moth" }
A{ noun = "entity", action = "add", kind = "item", name = "Brass Key", aliases = "the key" }
A{ noun = "entity", action = "add", kind = "item", name = "Old Map", parent = "Rome" }

-- ---- containers -----------------------------------------------------------------------------
do
  local ch = geo.ancestors(book, "cafe-lune")
  ok(#ch == 3 and ch[1] == "paris" and ch[3] == "europe", "ancestors nearest first")
  local d = geo.descendants(book, "france", "place")
  ok(#d == 3, "France holds Paris, Lyon, Cafe Lune")
end
local tree = A{ noun = "geo", action = "tree" }
has(tree, "Europe  [europe]", "tree roots"); has(tree, "    Paris  [paris]", "tree nests"); has(tree, "Isle of Mist", "a separate root")
has(A{ noun = "geo", action = "tree", name = "France" }, "Cafe Lune", "tree from a place")
iserr(A{ noun = "geo", action = "tree", name = "Vera" }, "tree needs a place")

-- ---- where / inside ---------------------------------------------------------------------------
has(A{ noun = "geo", action = "where", name = "Vera" }, "UNKNOWN", "no record is UNKNOWN, not a guess")
A{ noun = "event", action = "add", t = 1, summary = "Vera sits in the cafe", deltas = "move vera-lind to cafe-lune" }
A{ noun = "event", action = "add", t = 3, summary = "Vera takes the key", deltas = "vera-lind acquires brass-key" }
local w = A{ noun = "geo", action = "where", name = "Vera", as_of = 2 }
has(w, "at: cafe-lune", "where: her place"); has(w, "Cafe Lune > Paris > France > Europe", "where: names the chain")
has(w, "evidence: E1", "where: cites the event")
has(A{ noun = "geo", action = "where", name = "Vera", as_of = 0 }, "UNKNOWN", "before she arrives: unknown")
has(A{ noun = "geo", action = "inside", name = "Vera", of = "Paris", as_of = 2 }, "TRUE", "inside, one level up")
has(A{ noun = "geo", action = "inside", name = "Vera", of = "France", as_of = 2 }, "TRUE", "inside, two levels up")
has(A{ noun = "geo", action = "inside", name = "Vera", of = "Europe" }, "TRUE", "inside, three levels up")
local no = A{ noun = "geo", action = "inside", name = "Vera", of = "Rome" }
has(no, "FALSE", "not inside Rome"); has(no, "Cafe Lune > Paris > France > Europe", "false names the record")
has(A{ noun = "geo", action = "inside", name = "Cafe Lune", of = "Paris" }, "TRUE", "a place inside a place")
has(A{ noun = "geo", action = "inside", name = "Paris", of = "Paris" }, "TRUE", "a place is inside itself")
has(A{ noun = "geo", action = "inside", name = "Moth", of = "Paris" }, "UNKNOWN", "an unplaced character is unknown")
iserr(A{ noun = "geo", action = "inside", name = "Vera", of = "Moth" }, "of= must be a place")
iserr(A{ noun = "geo", action = "inside", name = "Vera" }, "inside needs of=")
-- an item: carried, then dropped
has(A{ noun = "geo", action = "where", name = "the key", as_of = 3 }, "carried by vera-lind", "an item is where its holder is")
has(A{ noun = "geo", action = "where", name = "the key", as_of = 2 }, "UNKNOWN", "before she took it: unknown")
has(A{ noun = "geo", action = "where", name = "Old Map" }, "its home (parent)", "an item with only a parent is at home")

-- ---- contents / between -----------------------------------------------------------------------------
local c = A{ noun = "geo", action = "contents", name = "France", as_of = 3 }
has(c, "vera-lind", "contents includes nested"); has(c, "brass-key", "contents includes what she carries")
hasnt(A{ noun = "geo", action = "contents", name = "France", as_of = 3, deep = false }, "vera-lind", "deep=false is direct only")
hasnt(A{ noun = "geo", action = "contents", name = "Italy", as_of = 3 }, "vera-lind", "not in Italy")
has(A{ noun = "geo", action = "contents", name = "Rome" }, "old-map", "a parent-placed item is in its place")
A{ noun = "event", action = "add", t = 4, summary = "Moth in Lyon", deltas = "move moth to lyon" }
has(A{ noun = "geo", action = "between", name = "Vera", other = "Moth", as_of = 5 }, "both within France", "smallest shared place")
A{ noun = "event", action = "add", t = 6, summary = "Moth to the isle", deltas = "move moth to isle-of-mist" }
has(A{ noun = "geo", action = "between", name = "Vera", other = "Moth", as_of = 7 }, "share no container", "no shared container")

-- ---- claims -------------------------------------------------------------------------------------------
has(A{ noun = "check", action = "claim", claim = "Vera in Paris", as_of = 2 }, "TRUE", "claim: in")
has(A{ noun = "check", action = "claim", claim = "Vera is in Rome", as_of = 2 }, "FALSE", "claim: is in")
has(A{ noun = "check", action = "claim", claim = "Vera at the cafe", as_of = 2 }, "TRUE", "claim: at, by alias")
has(A{ noun = "check", action = "claim", claim = "Vera holds the key", as_of = 3 }, "TRUE", "claim: holds")
has(A{ noun = "check", action = "claim", claim = "Moth holds the key", as_of = 3 }, "FALSE", "claim: held by someone else")
has(A{ noun = "check", action = "claim", claim = "Moth holds the key", as_of = 3 }, "held by Vera Lind", "...and says who")
has(A{ noun = "check", action = "claim", claim = "Moth holds the key", as_of = 1 }, "UNKNOWN", "claim: nothing known")
A{ noun = "event", action = "add", t = 8, summary = "mood", deltas = "vera-lind mood=calm; relate vera-lind moth trust +3" }
has(A{ noun = "check", action = "claim", claim = "Vera mood=calm", as_of = 9 }, "TRUE", "claim: field equals")
has(A{ noun = "check", action = "claim", claim = "Vera mood=angry", as_of = 9 }, "FALSE", "claim: field differs")
has(A{ noun = "check", action = "claim", claim = "Vera shoe=red", as_of = 9 }, "UNKNOWN", "claim: no such field")
A{ noun = "event", action = "add", t = 10, summary = "Moth dies", deltas = "end moth" }
has(A{ noun = "check", action = "claim", claim = "Moth alive", as_of = 9 }, "TRUE", "alive before the end")
has(A{ noun = "check", action = "claim", claim = "Moth alive", as_of = 11 }, "FALSE", "not alive after")
has(A{ noun = "check", action = "claim", claim = "Moth dead", as_of = 11 }, "TRUE", "dead after")
iserr(A{ noun = "check", action = "claim", claim = "blah" }, "unreadable claim")
iserr(A{ noun = "check", action = "claim", claim = "Nobody in Paris" }, "unknown name")
iserr(A{ noun = "check", action = "claim" }, "claim needs claim=")
has(A{ noun = "check", action = "claim", claim = "Vera knows F9" }, "no fact", "knows: unknown fact is an error")

-- ---- facts, respecting what is withheld ----------------------------------------------------------------------
A{ noun = "fact", action = "add", subject = "Paris", body = "Paris is wet in autumn." }
A{ noun = "fact", action = "add", subject = "Paris", body = "The Cafe Lune hides a tunnel.", withhold_until = 20 }
local fs = A{ noun = "check", action = "facts", name = "Paris", pos = 5 }
has(fs, "wet in autumn", "facts: visible"); hasnt(fs, "tunnel", "facts: withheld fact hidden"); has(fs, "withheld until later", "facts: says something is withheld")
has(A{ noun = "check", action = "facts", name = "Paris", pos = 25 }, "tunnel", "facts: visible once told")

-- ---- distance / travel -----------------------------------------------------------------------------------------
has(A{ noun = "geo", action = "distance", name = "Paris", other = "Rome" }, "UNKNOWN", "no coordinates: unknown")
has(A{ noun = "geo", action = "set", name = "Paris", lat = 48.8566, lon = 2.3522 }, "coordinates", "set coordinates")
A{ noun = "geo", action = "set", name = "Rome", lat = 41.9028, lon = 12.4964 }
local dist = A{ noun = "geo", action = "distance", name = "Cafe Lune", other = "Rome" }
has(dist, "TRUE", "a cafe borrows Paris's coordinates")
local km = tonumber(dist:match("(%d+) km"))
ok(km and km > 1050 and km < 1120, "Paris-Rome is about 1,100 km, got " .. tostring(km))
iserr(A{ noun = "geo", action = "set", name = "Paris", lat = 95, lon = 0 }, "bad latitude refused")
iserr(A{ noun = "geo", action = "set", name = "Vera", lat = 1, lon = 1 }, "only places get coordinates")
iserr(A{ noun = "geo", action = "set", name = "Paris" }, "set needs something to set")
has(A{ noun = "geo", action = "travel", name = "Paris", to = "Rome" }, "UNKNOWN", "no route: unknown, not impossible")
has(A{ noun = "geo", action = "travel", name = "Paris", to = "Rome", speed = 50 }, "lower bound", "speed gives a lower bound")
has(A{ noun = "geo", action = "set", name = "Paris", route_to = "Lyon", days = 2, mode = "coach" }, "route to lyon", "set a route")
A{ noun = "geo", action = "set", name = "Lyon", route_to = "Rome", days = 4 }
local tr = A{ noun = "geo", action = "travel", name = "Paris", to = "Rome" }
has(tr, "6.00 days", "shortest route is the sum"); has(tr, "paris > lyon > rome", "route is shown")
has(A{ noun = "geo", action = "travel", name = "Paris", to = "Rome", t1 = 0, t2 = 5 }, "FALSE", "five days is not enough")
has(A{ noun = "geo", action = "travel", name = "Paris", to = "Rome", t1 = 0, t2 = 6 }, "TRUE", "six days is enough")
has(A{ noun = "geo", action = "travel", name = "Paris", to = "Rome", t1 = 0, t2 = 48, per_day = 24 }, "FALSE", "per_day converts hours")
-- a traveller is measured from where they were
has(A{ noun = "geo", action = "travel", name = "Vera", to = "Rome", t1 = 2, t2 = 4 }, "FALSE", "Vera cannot reach Rome in two days from Paris")
has(A{ noun = "geo", action = "travel", name = "Vera", to = "Lyon", t1 = 2, t2 = 4 }, "TRUE", "...but Lyon is two days")
iserr(A{ noun = "geo", action = "travel", name = "Moth", to = "Rome", t1 = 0, t2 = 1 }, "a traveller with no place needs from=")

-- ---- the audit ----------------------------------------------------------------------------------------------------------
local clean = A{ noun = "check", action = "world" }
has(clean, "0 errors", "a sound world has no errors -- got " .. clean)
-- vera is in Paris (t=1); sending her to Rome at t=2 is a teleport once the routes are declared
A{ noun = "event", action = "add", t = 2.5, summary = "Vera in Rome", deltas = "move vera-lind to rome" }
local bad = A{ noun = "check", action = "world" }
has(bad, "teleport", "teleporting is found"); has(bad, "vera-lind", "...and names her")
-- same-time double move
A{ noun = "event", action = "add", t = 30, summary = "here", deltas = "move vera-lind to lyon" }
A{ noun = "event", action = "add", t = 30, summary = "and here", deltas = "move vera-lind to paris" }
has(A{ noun = "check", action = "world" }, "two_places_at_once", "two places at once")
-- a move to a non-place
A{ noun = "event", action = "add", t = 31, summary = "odd", deltas = "move vera-lind to brass-key" }
has(A{ noun = "check", action = "world" }, "move_to_non_place", "a move to an item")
-- a double hold
A{ noun = "event", action = "add", t = 32, summary = "grab", deltas = "moth acquires brass-key" }
has(A{ noun = "check", action = "world" }, "item_double_hold", "an item held twice")
-- acting after the end
has(A{ noun = "check", action = "world" }, "acts_after_end", "acting after the end")
-- the tree
sm.update_entity(book, "france", { parent = "cafe-lune" }, "test")
has(A{ noun = "check", action = "world" }, "place_cycle", "a place inside itself")
sm.update_entity(book, "france", { parent = "europe" }, "test")
ok(#(geo.ancestors(book, "cafe-lune")) == 3, "ancestors terminates even on a cycle (tested above)")
sm.update_entity(book, "lyon", { attrs = { routes = { { to = "nowhere", days = 1 } } } }, "test")
has(A{ noun = "check", action = "world" }, "route_to_nowhere", "a route to nowhere")

-- ---- the model only proposes ------------------------------------------------------------------------------------------------
local p = Mdl{ noun = "geo", action = "set", name = "Rome", route_to = "Paris", days = 7 }
has(p, "Proposed", "the model's geo set is a proposal")
local r = Mdl{ noun = "geo", action = "where", name = "Vera", as_of = 2 }
has(r, "at: cafe-lune", "the model can read")
has(Mdl{ noun = "check", action = "claim", claim = "Vera in Paris", as_of = 2 }, "TRUE", "the model can check claims")

-- ---- the code-driven skills -----------------------------------------------------------------------------------------------
do
  local wc, wl = require("skills.world_check"), require("skills.world_lookup")
  ok(type(wc.before) == "function" and type(wc.verify) == "function" and wc.description, "world_check has the callable shape")
  ok(type(wl.before) == "function" and wl.description, "world_lookup has the callable shape")
  local set = wc.before({ book = B }).set
  ok(set.world_audit:find("world audit:", 1, true) and type(set.world_errors) == "number", "world_check before runs the audit in code")
  ok(set.world_errors > 0, "the broken world has errors")
  local v = wc.verify(nil, { book = B })
  ok(type(v) == "string" and v:find("error%(s%)"), "world_check verify blocks while errors remain")
  ok(wc.instructions(set):find("Never assert where", 1, true), "world_check instructions carry the rules")
  local m = wl.before({ book = B }).set
  ok(m.world_map:find("Cafe Lune", 1, true), "world_lookup before carries the place map")
  ok(wl.instructions(m):find("UNKNOWN", 1, true), "world_lookup instructions explain UNKNOWN")
  -- a clean book passes the gate
  local B2 = fresh_dir("clean")
  local f2 = io.open(B2 .. "/.boggart/story.json", "w"); f2:write('{"title":"Clean"}'); f2:close()
  local ok2 = wc.verify(nil, { book = B2 })
  ok(ok2 == true, "a book with nothing wrong passes the gate")
  ok(wc.verify(nil, { book = B2 .. "/nope" }) == true, "no book at all: nothing to gate")
end

io.write(string.format("story_geo: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
