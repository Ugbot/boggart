-- story/geosql.lua -- the world as SQL: geo_km/geo_bearing, the place views, the
-- R*Tree-backed nearby search and the read-only `geo sql` lookup. No model.
for _, t in ipairs{ "st_entity", "st_alias", "st_event", "st_delta", "st_fact", "st_knows", "st_promise",
                    "st_exemption", "st_proposal", "st_change", "st_seq", "st_fts" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local sm, sc, gs = require("story.model"), require("story.core"), require("story.geosql")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function has(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) ~= nil, n .. " -- got: " .. tostring(s)) end
local function hasnt(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) == nil, n .. " -- got: " .. tostring(s)) end
local function iserr(s, n) ok(type(s) == "string" and s:find("^Error:") ~= nil, n .. " -- got: " .. tostring(s)) end

local base = os.getenv("HOME") .. "/stgs-" .. tostring(os.time())
sys.mkdir_p(base .. "/.boggart")
local f = io.open(base .. "/.boggart/story.json", "w"); f:write('{"title":"GeoSQL"}'); f:close()
local B = base
local book = require("story.book").load(B).name
local function A(a) a.book = B; a._author = true; return sc.call(a) end

local function place(name, parent) return A{ noun = "entity", action = "add", kind = "place", name = name, parent = parent } end
place("Europe"); place("France", "Europe"); place("Paris", "France"); place("Cafe Lune", "Paris")
place("Lyon", "France"); place("Italy", "Europe"); place("Rome", "Italy"); place("Isle of Mist")
A{ noun = "geo", action = "set", name = "Paris", lat = 48.8566, lon = 2.3522 }
A{ noun = "geo", action = "set", name = "Lyon", lat = 45.7640, lon = 4.8357 }
A{ noun = "geo", action = "set", name = "Rome", lat = 41.9028, lon = 12.4964 }
A{ noun = "geo", action = "set", name = "Paris", route_to = "Lyon", days = 2, mode = "road" }
A{ noun = "geo", action = "set", name = "Lyon", route_to = "Rome", days = 4, one_way = true }

-- ---- SQL functions --------------------------------------------------------------------------
local r = bog.db:query("SELECT geo_km(48.8566, 2.3522, 45.7640, 4.8357) AS km, geo_bearing(48.8566, 2.3522, 45.7640, 4.8357) AS b, geo_km(NULL,1,2,3) AS n")[1]
ok(r.km > 390 and r.km < 400, "Paris-Lyon is about 392 km, got " .. tostring(r.km))
ok(r.b > 145 and r.b < 155, "Lyon is south-east of Paris, got " .. tostring(r.b))
ok(r.n == nil, "a NULL argument gives NULL")
ok(bog.db:query("SELECT geo_km(10,20,10,20) AS z")[1].z == 0, "same point is 0 km")

-- ---- views ------------------------------------------------------------------------------------
ok(gs.ensure(), "views and rtree create")
ok(gs.ensure(), "ensure is idempotent")
local g = sm.q("SELECT id, lat, lon FROM st_place_geo WHERE book = ? ORDER BY id", { book })
local byid = {}; for _, x in ipairs(g) do byid[x.id] = x end
ok(byid.paris and byid.paris.lat == 48.8566, "Paris has its own coordinates")
ok(byid["cafe-lune"] and byid["cafe-lune"].lat == 48.8566, "the cafe borrows Paris's coordinates")
ok(byid["isle-of-mist"] == nil and byid.europe == nil, "places with no geography anywhere are absent")
local cl = sm.q("SELECT ancestor FROM st_place_closure WHERE book = ? AND descendant = 'cafe-lune' ORDER BY depth", { book })
ok(#cl == 3 and cl[1].ancestor == "paris" and cl[3].ancestor == "europe", "closure: every container, nearest first")
local rt = sm.q("SELECT dst, days FROM st_route WHERE book = ? AND src = 'lyon' ORDER BY dst", { book })
ok(#rt == 2 and rt[1].dst == "paris" and rt[2].dst == "rome", "two-way route is mirrored, one-way is not (from Lyon)")
ok(#sm.q("SELECT 1 FROM st_route WHERE book = ? AND src = 'rome'", { book }) == 0, "one-way route has no way back")

-- ---- nearby (R*Tree + exact) -------------------------------------------------------------------
ok(gs.index(book) == 4, "indexed the places that have coordinates (Paris, Cafe Lune, Lyon, Rome)")
local near = A{ noun = "geo", action = "nearby", name = "Paris", km = 500 }
has(near, "Lyon", "Lyon is within 500 km"); hasnt(near, "Rome", "Rome is not"); hasnt(near, "Paris  ", "the origin is not listed")
has(A{ noun = "geo", action = "nearby", name = "Paris", km = 1200 }, "Rome", "Rome is within 1200 km")
has(A{ noun = "geo", action = "nearby", lat = 45.0, lon = 5.0, km = 100 }, "Lyon", "by coordinates")
has(A{ noun = "geo", action = "nearby", name = "Isle of Mist", km = 100 }, "UNKNOWN", "no coordinates: unknown")
iserr(A{ noun = "geo", action = "nearby", name = "Paris" }, "needs a radius")
-- re-indexing after a change does not leave stale rows
A{ noun = "geo", action = "set", name = "Lyon", lat = 10.0, lon = 10.0 }
hasnt(A{ noun = "geo", action = "nearby", name = "Paris", km = 500 }, "Lyon", "Lyon moved away")

-- ---- read-only SQL ------------------------------------------------------------------------------
local out = A{ noun = "geo", action = "sql", query = "SELECT name FROM st_place WHERE book = :book AND parent = 'france' ORDER BY name" }
has(out, "2 row(s)", "sql: counted"); has(out, "Lyon", "sql: a row"); has(out, "Paris", "sql: another row")
has(A{ noun = "geo", action = "sql", query = "WITH x AS (SELECT 1 AS a) SELECT a FROM x" }, "1 row(s)", "WITH is allowed")
iserr(A{ noun = "geo", action = "sql", query = "DELETE FROM st_entity" }, "delete refused")
iserr(A{ noun = "geo", action = "sql", query = "SELECT 1; DROP TABLE st_entity" }, "two statements refused")
iserr(A{ noun = "geo", action = "sql", query = "SELECT * FROM st_entity WHERE name = 'x' UNION SELECT 1 /* pragma */" }, "keywords refused even in comments")
iserr(A{ noun = "geo", action = "sql", query = "SELECT FROM" }, "bad sql is an error, not a crash")
ok(#sm.q("SELECT 1 FROM st_entity WHERE book = ?", { book }) > 0, "nothing was deleted")
-- the book scope is the caller's to write; other books' rows are not leaked when they do
sm.q("SELECT 1")
local scoped = gs.query(book, "SELECT COUNT(*) AS n FROM st_place WHERE book = :book")
ok(scoped and scoped[1].n == 8, "scoped count of places")

io.write(string.format("story_geosql: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
