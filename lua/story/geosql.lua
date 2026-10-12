-- story/geosql.lua -- the world's geography as SQL, so it can be queried freely.
--
-- The story model already lives in SQLite (st_entity, st_event, st_delta ...).
-- This adds, on the same connection:
--
--   functions   geo_km(lat1,lon1,lat2,lon2)       great-circle km   (src/ldb.c)
--               geo_bearing(lat1,lon1,lat2,lon2)  degrees 0..360
--   views       st_place          book,id,name,parent,lat,lon     (own coordinates)
--               st_place_geo      book,id,lat,lon                 (own, else the nearest container's)
--               st_place_closure  book,ancestor,descendant,depth  (every container, any depth)
--               st_route          book,src,dst,days,mode          (declared routes; two-way unless one_way)
--   rtree       st_place_rt       id,minlat,maxlat,minlon,maxlon  (rebuilt by M.index; for bbox / nearby)
--
-- Everything is derived from the model, so the model stays the one authority:
-- views read it live, and the R*Tree is only an index over it (M.index rebuilds it).
-- Pure SQL; nothing here asks a model anything.
local sm = require("story.model")

local M = {}

local VIEWS = {
  [[CREATE VIEW IF NOT EXISTS st_place AS
      SELECT book, id, name, parent,
             json_extract(attrs, '$.lat') AS lat, json_extract(attrs, '$.lon') AS lon
        FROM st_entity WHERE kind = 'place']],
  -- walk up from each place until a container carries coordinates (depth-capped: cycles end)
  [[CREATE VIEW IF NOT EXISTS st_place_geo AS
      WITH RECURSIVE up(book, id, cur, depth, lat, lon) AS (
        SELECT book, id, id, 0, lat, lon FROM st_place
        UNION ALL
        SELECT u.book, u.id, p.id, u.depth + 1, p.lat, p.lon
          FROM up u
          JOIN st_place c ON c.book = u.book AND c.id = u.cur
          JOIN st_place p ON p.book = u.book AND p.id = c.parent
         WHERE u.lat IS NULL AND u.depth < 32)
      SELECT book, id, lat, lon FROM up WHERE lat IS NOT NULL AND lon IS NOT NULL]],
  [[CREATE VIEW IF NOT EXISTS st_place_closure AS
      WITH RECURSIVE c(book, ancestor, descendant, depth) AS (
        SELECT book, parent, id, 1 FROM st_place WHERE parent IS NOT NULL AND parent <> ''
        UNION ALL
        SELECT c.book, p.parent, c.descendant, c.depth + 1
          FROM c JOIN st_place p ON p.book = c.book AND p.id = c.ancestor
         WHERE p.parent IS NOT NULL AND p.parent <> '' AND c.depth < 32)
      SELECT book, ancestor, descendant, depth FROM c]],
  [[CREATE VIEW IF NOT EXISTS st_route AS
      SELECT e.book AS book, e.id AS src, json_extract(r.value, '$.to') AS dst,
             json_extract(r.value, '$.days') AS days, json_extract(r.value, '$.mode') AS mode
        FROM st_entity e, json_each(e.attrs, '$.routes') r
       WHERE e.kind = 'place'
      UNION ALL
      SELECT e.book, json_extract(r.value, '$.to'), e.id,
             json_extract(r.value, '$.days'), json_extract(r.value, '$.mode')
        FROM st_entity e, json_each(e.attrs, '$.routes') r
       WHERE e.kind = 'place' AND COALESCE(json_extract(r.value, '$.one_way'), 0) = 0]],
}

local ready = false
function M.ensure()
  if ready then return true end
  local ok, err = sm.ensure_schema()
  if not ok then return nil, err end
  local db = bog.db
  -- the R*Tree is keyed by an integer, so a side table maps it to (book, place id)
  for _, sql in ipairs{
    [[CREATE TABLE IF NOT EXISTS st_place_rt_map (rid INTEGER PRIMARY KEY, book TEXT, id TEXT,
        UNIQUE (book, id))]],
    [[CREATE VIRTUAL TABLE IF NOT EXISTS st_place_rt USING rtree(rid, minlat, maxlat, minlon, maxlon)]],
  } do
    local r, e = db:exec(sql); if not r then return nil, e end
  end
  for _, sql in ipairs(VIEWS) do
    local r, e = db:exec(sql); if not r then return nil, e end
  end
  ready = true
  return true
end

-- Rebuild one book's slice of the R*Tree from st_place_geo. Returns the place count.
function M.index(book)
  local ok, err = M.ensure(); if not ok then return nil, err end
  local db = bog.db
  local old = db:query("SELECT rid FROM st_place_rt_map WHERE book = ?", { book }) or {}
  for _, r in ipairs(old) do db:run("DELETE FROM st_place_rt WHERE rid = ?", { r.rid }) end
  db:run("DELETE FROM st_place_rt_map WHERE book = ?", { book })
  local n = 0
  for _, p in ipairs(db:query("SELECT id, lat, lon FROM st_place_geo WHERE book = ?", { book }) or {}) do
    local m = db:run("INSERT INTO st_place_rt_map (book, id) VALUES (?, ?)", { book, p.id })
    if m then
      db:run("INSERT INTO st_place_rt VALUES (?, ?, ?, ?, ?)", { m.rowid, p.lat, p.lat, p.lon, p.lon })
      n = n + 1
    end
  end
  return n
end

-- Places within `km` of a point, nearest first. The R*Tree narrows by bounding box;
-- geo_km makes it exact.
function M.nearby(book, lat, lon, km, limit)
  local ok, err = M.index(book); if not ok then return nil, err end
  local dlat = km / 111.195
  local cosl = math.max(0.01, math.cos(math.rad(lat)))
  local dlon = math.min(180, km / (111.195 * cosl))
  return sm.q([[SELECT p.id AS id, p.name AS name, g.lat AS lat, g.lon AS lon,
                       geo_km(?, ?, g.lat, g.lon) AS km,
                       geo_bearing(?, ?, g.lat, g.lon) AS bearing
                  FROM st_place_rt rt
                  JOIN st_place_rt_map m ON m.rid = rt.rid AND m.book = ?
                  JOIN st_place p ON p.book = m.book AND p.id = m.id
                  JOIN st_place_geo g ON g.book = p.book AND g.id = p.id
                 WHERE rt.minlat >= ? AND rt.maxlat <= ? AND rt.minlon >= ? AND rt.maxlon <= ?
                   AND geo_km(?, ?, g.lat, g.lon) <= ?
                 ORDER BY km LIMIT ?]],
    { lat, lon, lat, lon, book, lat - dlat, lat + dlat, lon - dlon, lon + dlon, lat, lon, km, limit or 50 })
end

-- Read-only SQL over the world. One SELECT / WITH statement, scoped to a book by the
-- caller writing `book = :book` (bound here), capped in rows.
function M.query(book, sql, limit)
  local ok, err = M.ensure(); if not ok then return nil, err end
  sql = tostring(sql or ""):gsub("^%s+", ""):gsub("[%s;]+$", "")
  local low = sql:lower()
  if not (low:match("^select%s") or low:match("^with%s")) then return nil, "only a single SELECT (or WITH ... SELECT) is allowed" end
  if sql:find(";", 1, true) then return nil, "one statement only, no ';'" end
  for _, w in ipairs{ "insert", "update", "delete", "drop", "alter", "create", "attach", "pragma", "replace", "vacuum" } do
    if low:find("%f[%w_]" .. w .. "%f[^%w_]") then return nil, "read-only: '" .. w .. "' is not allowed" end
  end
  local n = 0
  sql = sql:gsub(":book", function() n = n + 1; return "?" end)
  local params = {}
  for i = 1, n do params[i] = book end
  local rows, e = bog.db:query("SELECT * FROM (" .. sql .. ") LIMIT " .. math.floor(tonumber(limit) or 50), params)
  if not rows then return nil, e end
  return rows
end

return M
