-- story/geotool.lua -- the `story` tool's `geo` and `check` nouns over the world
-- lookups in lua/story/geo.lua. All code: nothing here asks a model.
--
--   geo   where | inside | contents | tree | between | distance | travel | set
--   check claim | facts | world | travel
--
-- Reads need no author; `geo set` writes place data (coordinates, routes), which
-- follows the same rule as every write in the story model: the author's own
-- /story command applies it, the model's tool call becomes a proposal.
local sb = require("story.book")
local sm = require("story.model")
local geo = require("story.geo")
local geosql = require("story.geosql")
local M = {}

local function E(m) return "Error: " .. m end

local function open(a)
  local b, e = sb.resolve(a.book)
  if not b then return nil, e end
  sm.ensure_schema()
  sm.sync_in(b.name, b.root)
  return b
end

local function as_of(a) return tonumber(a.as_of or a.t) end

-- ids -> display names, for "Cafe Lune > Paris > France"
local function named(book, ids)
  local out = {}
  for _, id in ipairs(ids or {}) do
    local e = sm.entity(book, id)
    out[#out + 1] = e and e.name or id
  end
  return table.concat(out, " > ")
end

local function ev_line(ev)
  if not ev then return nil end
  return string.format("  evidence: %s (t=%s)%s", tostring(ev.event), tostring(ev.t),
    (ev.summary and ev.summary ~= "") and (": " .. ev.summary) or "")
end

local function verdict_text(r, book)
  local out = { string.upper(r.verdict) .. " -- " .. tostring(r.why or "") }
  if r.chain and #r.chain > 0 then out[#out + 1] = "  containers: " .. (book and named(book, r.chain) or table.concat(r.chain, " > ")) end
  local e = ev_line(r.evidence)
  if e then out[#out + 1] = e end
  if r.via then out[#out + 1] = "  carried by: " .. r.via end
  return table.concat(out, "\n")
end

local function when(t) return t and ("as of t=" .. t) or "now" end

-- ---- geo ------------------------------------------------------------------------------------
local function geo_where(a)
  local b, e = open(a); if not b then return E(e) end
  local en, ee = sm.resolve1(b.name, a.name or a.id); if not en then return E(ee) end
  local t = as_of(a)
  local r = geo.where(b.name, en.id, t)
  local out = { string.format("%s (%s) %s", r.name, r.kind, when(t)) }
  if r.ended then out[#out + 1] = "ENDED at t=" .. tostring(r.ended) end
  if not r.place then
    out[#out + 1] = "UNKNOWN -- nothing in the book says where this is" .. (r.via and (" (carried by " .. r.via .. ", whose place is not recorded)") or "")
    return table.concat(out, "\n")
  end
  local how = ({ self = "a place", move = "last moved there", held = "carried by " .. tostring(r.via), parent = "its home (parent)" })[r.source] or ""
  out[#out + 1] = "at: " .. r.place .. "   (" .. how .. ")"
  out[#out + 1] = "within: " .. named(b.name, r.chain)
  local l = ev_line(r.evidence); if l then out[#out + 1] = l end
  return table.concat(out, "\n")
end

local function geo_inside(a)
  local b, e = open(a); if not b then return E(e) end
  local of = a.of or a.to or a.other
  if not of then return E("geo inside needs name= (the thing) and of= (the place)") end
  local r, err = geo.inside(b.name, a.name, of, as_of(a)); if not r then return E(err) end
  return verdict_text(r, b.name) .. "\n(" .. when(as_of(a)) .. ")"
end

local function geo_contents(a)
  local b, e = open(a); if not b then return E(e) end
  local r, err = geo.contents(b.name, a.name, as_of(a), { deep = a.deep, kind = a.kind }); if not r then return E(err) end
  local out = { string.format("%s %s%s", r.name, when(as_of(a)), a.deep == false and " (direct only)" or " (nested places included)") }
  if #r.places > 0 then out[#out + 1] = "places inside: " .. table.concat(r.places, ", ") end
  if #r.here == 0 then out[#out + 1] = "nothing recorded here" end
  local last
  for _, h in ipairs(r.here) do
    if h.kind ~= last then out[#out + 1] = "## " .. h.kind; last = h.kind end
    out[#out + 1] = string.format("  %-22s at %s%s", h.id, h.place, h.via and (" (carried by " .. h.via .. ")") or "")
  end
  return table.concat(out, "\n")
end

local function geo_tree(a)
  local b, e = open(a); if not b then return E(e) end
  local lines, err = geo.tree(b.name, a.name, a.depth); if not lines then return E(err) end
  if #lines == 0 then return "No places yet." end
  return table.concat(lines, "\n")
end

local function geo_between(a)
  local b, e = open(a); if not b then return E(e) end
  local other = a.other or a.to or a.of
  if not other then return E("geo between needs name= and other=") end
  local r, err = geo.between(b.name, a.name, other, as_of(a)); if not r then return E(err) end
  return string.upper(r.verdict) .. " -- " .. tostring(r.why)
end

local function geo_distance(a)
  local b, e = open(a); if not b then return E(e) end
  local other = a.other or a.to or a.of
  if not other then return E("geo distance needs name= and other=") end
  local r, err = geo.distance(b.name, a.name, other); if not r then return E(err) end
  return string.upper(r.verdict) .. " -- " .. tostring(r.why)
end

-- geo travel: how long between two places, and (with t1/t2) whether it fits.
-- name= the traveller or a place; to= the destination; from= a place when name is a traveller.
local function travel(a)
  local b, e = open(a); if not b then return E(e) end
  local to = a.to or a.other or a.of
  if not (a.name and to) then return E("travel needs name= (a traveller or a place) and to= (a place)") end
  local en, ee = sm.resolve1(b.name, a.name); if not en then return E(ee) end
  local from = en.id
  local t1, t2 = tonumber(a.t1), tonumber(a.t2)
  if en.kind ~= "place" then
    local at = a.from and { place = (sm.resolve1(b.name, a.from) or {}).id } or geo.where(b.name, en.id, t1)
    if not at.place then return E(en.name .. " has no recorded place" .. (t1 and (" as of t=" .. t1) or "") .. "; pass from=") end
    from = at.place
  end
  local opts = { per_day = a.per_day, speed = a.speed }
  local r, err
  if t1 and t2 then r, err = geo.travel_check(b.name, from, to, t1, t2, opts)
  else r, err = geo.travel_time(b.name, from, to, opts) end
  if not r then return E(err) end
  local out = { string.upper(r.verdict) .. " -- " .. tostring(r.why or (string.format("%.2f days (%s)", r.days or 0, r.how or ""))) }
  if r.path and #r.path > 1 then out[#out + 1] = "  route: " .. table.concat(r.path, " > ") end
  return table.concat(out, "\n")
end

-- geo set: coordinates and routes on a place. name= place; lat=, lon=;
-- route_to= another place with days= (and mode=, one_way=true).
local function geo_set(a)
  local b, e = open(a); if not b then return E(e) end
  local pl, pe = sm.resolve1(b.name, a.name or a.id); if not pl then return E(pe) end
  if pl.kind ~= "place" then return E(pl.id .. " is a " .. pl.kind .. ", not a place") end
  local attrs, did = {}, {}
  if a.lat ~= nil or a.lon ~= nil then
    local lat, lon = tonumber(a.lat), tonumber(a.lon)
    if not (lat and lon) then return E("lat= and lon= together, as numbers") end
    if math.abs(lat) > 90 or math.abs(lon) > 180 then return E("lat is -90..90 and lon is -180..180") end
    attrs.lat, attrs.lon = lat, lon
    did[#did + 1] = string.format("coordinates %.4f, %.4f", lat, lon)
  end
  if a.route_to then
    local dest, de = sm.resolve1(b.name, a.route_to); if not dest then return E(de) end
    if dest.kind ~= "place" then return E(dest.id .. " is a " .. dest.kind .. ", not a place") end
    local days = tonumber(a.days)
    if not days or days < 0 then return E("route_to needs days= (a number >= 0)") end
    local json = require("json")
    local cur = {}
    local ok, at = pcall(json.decode, pl.attrs or "{}")
    for _, r in ipairs((ok and type(at) == "table" and type(at.routes) == "table") and at.routes or {}) do
      if r.to ~= dest.id then cur[#cur + 1] = r end
    end
    cur[#cur + 1] = { to = dest.id, days = days, mode = a.mode, one_way = a.one_way == true or nil }
    attrs.routes = cur
    did[#did + 1] = string.format("route to %s: %g days%s", dest.id, days, a.one_way and " (one way)" or "")
  end
  if next(attrs) == nil then return E("geo set needs lat=+lon= and/or route_to=+days=") end
  local payload = { id = pl.id, attrs = attrs }
  local summary = pl.id .. ": " .. table.concat(did, "; ")
  if a._author then
    local res, err = sm.APPLY["entity.update"](b.name, payload, "author")
    if not res then return E(tostring(err)) end
    sm.export(b.name, b.root)
    return "geo set " .. summary
  end
  local id, perr = sm.propose(b.name, { kind = "entity", action = "update", payload = payload, summary = summary,
    origin = a.origin or "model", grp = a.group }, b.root)
  if not id then return E(tostring(perr)) end
  sm.export(b.name, b.root)
  return string.format("Proposed %s: %s\n(Canon changes only when the author accepts it: /story proposal accept ids=%s)", id, summary, id)
end

-- ---- check ------------------------------------------------------------------------------------
local function check_claim(a)
  local b, e = open(a); if not b then return E(e) end
  local c = a.claim or a.text
  if not c then return E("check claim needs claim=\"vera in paris\" (or: vera holds key | moth alive | vera mood=calm | vera knows F3)") end
  local r, err = geo.claim(b.name, c, as_of(a)); if not r then return E(err) end
  return verdict_text(r, b.name) .. "\n(" .. when(as_of(a)) .. ")"
end

-- Canon facts about something, as of a story time and (optionally) a narrative
-- position, with what is withheld, claimed or only rumoured kept visible as such.
local function check_facts(a)
  local b, e = open(a); if not b then return E(e) end
  local en, ee = sm.resolve1(b.name, a.name or a.subject); if not en then return E(ee) end
  local t, pos = as_of(a), tonumber(a.pos)
  local rows = sm.facts_at(b.name, t, { subject = en.id, pos = pos })
  local out = { string.format("canon facts about %s (%s)%s", en.name, when(t), pos and (", visible at pos " .. pos) or "") }
  if #rows == 0 then out[#out + 1] = "  none" end
  for _, f in ipairs(rows) do
    local tag = f.modality ~= "true" and (" [" .. f.modality .. (f.holder and (" by " .. f.holder) or "") .. "]") or ""
    out[#out + 1] = string.format("  %s%s%s  %s", f.id, tag, f.visibility == "secret" and " [secret]" or "", f.body)
  end
  -- what exists but is not visible yet, so "no fact" is not read as "no such fact"
  if pos then
    local hidden = 0
    for _, f in ipairs(sm.facts_at(b.name, t, { subject = en.id })) do
      if f.withhold_until and f.withhold_until > pos then hidden = hidden + 1 end
    end
    if hidden > 0 then out[#out + 1] = string.format("  (%d more canon fact(s) withheld until later in the telling)", hidden) end
  end
  local w = geo.where(b.name, en.id, t)
  if w.place then out[#out + 1] = "  located: " .. named(b.name, w.chain) end
  return table.concat(out, "\n")
end

local function check_world(a)
  local b, e = open(a); if not b then return E(e) end
  local rep = geo.audit(b.name, { per_day = a.per_day, speed = a.speed })
  return geo.audit_text(rep)
end

-- ---- SQL lookups ----------------------------------------------------------------------------
local function geo_nearby(a)
  local b, e = open(a); if not b then return E(e) end
  local lat, lon = tonumber(a.lat), tonumber(a.lon)
  local from
  if not (lat and lon) then
    local en, ee = sm.resolve1(b.name, a.name); if not en then return E(ee .. " (or give lat= lon=)") end
    local ok, err = geosql.ensure(); if not ok then return E(err) end
    local g = sm.q("SELECT lat, lon FROM st_place_geo WHERE book = ? AND id = ?", { b.name, en.id })
    if not g[1] then return "UNKNOWN -- " .. en.name .. " has no coordinates (here or in a container): geo set name= lat= lon=" end
    lat, lon, from = g[1].lat, g[1].lon, en
  end
  local km = tonumber(a.km or a.radius)
  if not km or km <= 0 then return E("geo nearby needs km= (radius, > 0)") end
  local rows, err = geosql.nearby(b.name, lat, lon, km, tonumber(a.limit))
  if not rows then return E(err) end
  local out = { string.format("places within %g km of %s", km, from and from.name or string.format("%.4f, %.4f", lat, lon)) }
  local n = 0
  for _, r in ipairs(rows) do
    if not (from and r.id == from.id) then
      n = n + 1
      out[#out + 1] = string.format("  %-24s %8.1f km  bearing %3.0f", r.name, r.km, r.bearing)
    end
  end
  if n == 0 then out[#out + 1] = "  none (places without coordinates are not searched)" end
  return table.concat(out, "\n")
end

local function geo_sql(a)
  local b, e = open(a); if not b then return E(e) end
  local rows, err = geosql.query(b.name, a.query or a.sql, a.limit)
  if not rows then return E(err) end
  local json = require("json")
  local out = { string.format("%d row(s)", #rows) }
  for _, r in ipairs(rows) do out[#out + 1] = "  " .. json.encode(r) end
  return table.concat(out, "\n")
end

M.ACTIONS = {
  geo = { where = geo_where, inside = geo_inside, contents = geo_contents, tree = geo_tree,
          between = geo_between, distance = geo_distance, travel = travel, set = geo_set,
          nearby = geo_nearby, sql = geo_sql },
  check = { claim = check_claim, facts = check_facts, world = check_world, travel = travel },
}
M.DEFAULT = { geo = "where", check = "claim" }

M.DESCRIPTION = "WORLD LOOKUPS (code only, no guessing; answers are TRUE, FALSE or UNKNOWN -- unknown means the book does "
  .. "not say, never false; false always names the record that makes it false): "
  .. "geo where name= (as_of=: its place and the chain of containers, e.g. Cafe > Paris > France)|"
  .. "inside name= of= (is it within that place, nested)|contents name=place (deep=false for direct only, kind=)|"
  .. "tree (name=place to start from)|between name= other= (smallest place they share)|"
  .. "distance name= other= (km, needs lat/lon)|travel name=traveller-or-place to=place t1= t2= (per_day=, speed=km/day: "
  .. "does the journey fit in the time)|nearby name=place-or-lat=+lon= km= (places within the radius, nearest first, with bearing)|"
  .. "sql query=\"SELECT ...\" (read-only over the world: st_place(id,name,parent,lat,lon), st_place_geo (effective "
  .. "lat/lon), st_place_closure(ancestor,descendant,depth), st_route(src,dst,days,mode), st_entity, st_event, st_delta; "
  .. "filter with book = :book; geo_km(lat1,lon1,lat2,lon2) and geo_bearing() are SQL functions)|set name=place lat= lon= | route_to=place days= mode= one_way=; "
  .. "check claim=\"vera in paris\"|\"vera holds key\"|\"moth alive\"|\"vera mood=calm\"|\"vera trust>=3\"|\"vera knows F3\" (as_of=)|"
  .. "facts name= (as_of=, pos= hides what is withheld)|world (audit: place-tree cycles, moves to non-places, two places at "
  .. "once, teleporting past declared routes, items held twice, acting after death). Check a claim BEFORE writing it into prose."

M.PROPS = {
  of = { type = "string", description = "the place a thing is asked to be within" },
  other = { type = "string" }, to = { type = "string", description = "destination place" },
  from = { type = "string", description = "starting place (travel)" },
  deep = { type = "boolean", description = "contents: include nested places (default true)" },
  depth = { type = "integer" }, lat = { type = "number" }, lon = { type = "number" },
  route_to = { type = "string" }, days = { type = "number" }, one_way = { type = "boolean" },
  claim = { type = "string", description = "one claim to verify, e.g. 'vera in paris'" },
  t1 = { type = "number" }, t2 = { type = "number" },
  per_day = { type = "number", description = "story-time units per day (default 1)" },
  speed = { type = "number", description = "km per day, for a straight-line lower bound" },
  km = { type = "number", description = "nearby: radius in km" },
  query = { type = "string", description = "geo sql: one read-only SELECT" },
}

return M
