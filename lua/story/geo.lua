-- story/geo.lua -- where things are in a book's world, and whether a claim about
-- the world is true. Code only: no model is asked anything here. It reads the
-- story model (lua/story/model.lua) -- the place tree (`parent`), canon `move`
-- deltas, holdings, facts -- and answers from that.
--
--   where       X: its place and the chain of containers around it (Cafe > Paris > France)
--   inside      is X within Y (transitively)? true / false / unknown, with the evidence
--   contents    what is in a place, nested places included
--   tree        the place hierarchy
--   between     the smallest place two things share
--   distance    straight-line km between two places that have coordinates
--   travel      the shortest declared route, and whether a journey fits in the time given
--   claim       one plain-text claim ("vera in paris", "vera holds key", "moth alive",
--               "vera mood=calm", "vera knows F3"), checked against the world as of t
--   audit       every deterministic world check at once (see M.audit)
--
-- OPEN WORLD. A book never states everything, so an answer is `true`, `false`
-- or `unknown`; "no record" is never reported as "false". `false` always comes
-- with the record that makes it false.
--
-- GEOGRAPHY DATA lives on the place entity's attrs, set with `geo set`:
--   lat, lon            degrees, for straight-line distance
--   routes              { {to = <place id>, days = n, mode = "road"|..., one_way = bool}, ... }
-- A place with neither borrows the nearest container that has them, so a cafe in
-- Paris travels as Paris does.
local sm = require("story.model")
local json = require("json")

local M = {}

local q = sm.q
local function one(sql, p) return q(sql, p)[1] end

M.UNKNOWN, M.TRUE, M.FALSE = "unknown", "true", "false"
M.EARTH_KM = 6371.0088

-- ---- entities ----------------------------------------------------------------------------
local function ent(book, name)
  if name == nil or name == "" then return nil, "a name is needed" end
  return sm.resolve1(book, name)
end

local function attrs_of(e)
  if not e then return {} end
  local ok, a = pcall(json.decode, e.attrs or "{}")
  return (ok and type(a) == "table") and a or {}
end

local function place_row(book, id)
  local e = sm.entity(book, id)
  return e
end

local function is_place(e) return e and e.kind == "place" end

-- ---- the place tree ------------------------------------------------------------------------
-- Containers of `id`, nearest first. Cycle-safe: returns chain, cyclic (bool).
function M.ancestors(book, id)
  local chain, seen = {}, { [id] = true }
  local cur = sm.entity(book, id)
  while cur and cur.parent and cur.parent ~= "" do
    if seen[cur.parent] then return chain, true end
    seen[cur.parent] = true
    local p = sm.entity(book, cur.parent)
    if not p then chain[#chain + 1] = cur.parent .. " (missing)"; break end
    chain[#chain + 1] = p.id
    cur = p
  end
  return chain, false
end

-- Everything inside `id` (any depth), as { id = depth }, and the list in
-- breadth-first order. Cycle-safe.
function M.descendants(book, id, kind)
  local depth, order, queue = { [id] = 0 }, {}, { id }
  local sql = "SELECT id, kind FROM st_entity WHERE book = ? AND parent = ? AND status != 'retconned' ORDER BY id"
  local head = 1
  while head <= #queue do
    local cur = queue[head]; head = head + 1
    for _, r in ipairs(q(sql, { book, cur })) do
      if depth[r.id] == nil then
        depth[r.id] = depth[cur] + 1
        queue[#queue + 1] = r.id
        if not kind or r.kind == kind then order[#order + 1] = r.id end
      end
    end
  end
  depth[id] = nil
  return order, depth
end

local function names(book, ids)
  local out = {}
  for _, id in ipairs(ids) do
    local e = sm.entity(book, id)
    out[#out + 1] = e and e.name or id
  end
  return out
end

local function chain_text(book, ids)
  return table.concat(names(book, ids), " > ")
end

-- ---- the world at time t: one pass over canon deltas -----------------------------------------
-- Returns { place = {entity -> place id}, moved_by = {entity -> {event,t}},
--           holder = {item -> entity}, held_by = {item -> {event,t}}, ended = {entity -> t} }.
function M.world_at(book, t)
  t = tonumber(t) or math.huge
  local w = { place = {}, moved_by = {}, holder = {}, held_by = {}, ended = {} }
  for _, d in ipairs(q([[SELECT d.op, d.entity, d.target, e.t AS t, e.id AS ev, e.summary AS summary
                         FROM st_delta d JOIN st_event e ON e.book = d.book AND e.id = d.event
                         WHERE d.book = ? AND e.status = 'canon' AND e.t <= ?
                         ORDER BY e.t, e.id, d.n]], { book, t })) do
    if d.op == "move" then
      w.place[d.entity] = d.target
      w.moved_by[d.entity] = { event = d.ev, t = d.t, summary = d.summary }
    elseif d.op == "acquire" then
      w.holder[d.target] = d.entity
      w.held_by[d.target] = { event = d.ev, t = d.t, summary = d.summary }
    elseif d.op == "lose" then
      if w.holder[d.target] == d.entity then w.holder[d.target] = nil end
      w.held_by[d.target] = { event = d.ev, t = d.t, summary = d.summary }
    elseif d.op == "end" then
      w.ended[d.entity] = d.t
    elseif d.op == "create" then
      w.ended[d.entity] = nil
    end
  end
  return w
end

-- Where `id` is at t. -> { id, kind, place = <place id>|nil, source = "self"|"move"|"held"|"parent",
--   chain = { place, container, ... }, via = <holder>, evidence = {event,t,summary}, ended = t|nil }
function M.where(book, id, t, w)
  local e = sm.entity(book, id)
  if not e then return nil, "no entity " .. tostring(id) end
  w = w or M.world_at(book, t)
  local r = { id = e.id, name = e.name, kind = e.kind, ended = w.ended[e.id] }
  local function finish(place, source, evidence, via)
    r.place, r.source, r.evidence, r.via = place, source, evidence, via
    if place then
      r.chain = { place }
      for _, a in ipairs((M.ancestors(book, place))) do r.chain[#r.chain + 1] = a end
    end
    return r
  end
  if e.kind == "place" then
    return finish(e.id, "self")
  end
  if e.kind == "item" and w.holder[e.id] then
    local h = M.where(book, w.holder[e.id], t, w)
    if h and h.place then
      return finish(h.place, "held", w.held_by[e.id], w.holder[e.id])
    end
    r.via = w.holder[e.id]
    return finish(nil, "held", w.held_by[e.id], w.holder[e.id])
  end
  if w.place[e.id] then
    return finish(w.place[e.id], "move", w.moved_by[e.id])
  end
  if e.parent and e.parent ~= "" then
    local p = sm.entity(book, e.parent)
    if p and p.kind == "place" then return finish(p.id, "parent") end
  end
  return finish(nil, nil)
end

-- ---- inside / contents -------------------------------------------------------------------------
-- -> { verdict, why, chain, evidence }
function M.inside(book, x, y, t)
  local ex, e1 = ent(book, x); if not ex then return nil, e1 end
  local ey, e2 = ent(book, y); if not ey then return nil, e2 end
  if not is_place(ey) then return nil, ey.id .. " is a " .. ey.kind .. ", not a place" end
  local loc = M.where(book, ex.id, t)
  if ex.id == ey.id then
    return { verdict = M.TRUE, why = ex.name .. " is " .. ey.name, chain = loc.chain or {} }
  end
  if not loc.place then
    return { verdict = M.UNKNOWN, why = "nothing in the book says where " .. ex.name .. " is" .. (t and (" as of t=" .. t) or ""),
             chain = {} }
  end
  for _, c in ipairs(loc.chain) do
    if c == ey.id then
      return { verdict = M.TRUE, chain = loc.chain, evidence = loc.evidence, source = loc.source, via = loc.via,
        why = string.format("%s is in %s, which is within %s", ex.name, names(book, { loc.place })[1], ey.name) }
    end
  end
  -- X has a recorded place and Y is not among its containers: false, with the
  -- chain that says so (an author who means otherwise fixes the tree).
  return { verdict = M.FALSE, chain = loc.chain, evidence = loc.evidence, source = loc.source, via = loc.via,
    why = string.format("%s is in %s (%s), not within %s", ex.name, names(book, { loc.place })[1],
      chain_text(book, loc.chain), ey.name) }
end

-- What is in `place` at t. opts.deep (default true) includes nested places.
-- -> { place, here = { {id,kind,name,place,source} }, places = { sub-place ids }, items = ... }
function M.contents(book, place, t, opts)
  opts = opts or {}
  local ep, e = ent(book, place); if not ep then return nil, e end
  if not is_place(ep) then return nil, ep.id .. " is a " .. ep.kind .. ", not a place" end
  local deep = opts.deep ~= false
  local inside = { [ep.id] = true }
  local subs = M.descendants(book, ep.id, "place")
  if deep then for _, s in ipairs(subs) do inside[s] = true end end
  local w = M.world_at(book, t)
  local out = { place = ep.id, name = ep.name, places = subs, here = {} }
  local rows = q("SELECT id, kind, name, parent FROM st_entity WHERE book = ? AND kind != 'place' AND status != 'retconned' ORDER BY kind, id", { book })
  for _, r in ipairs(rows) do
    local loc = M.where(book, r.id, t, w)
    if loc and loc.place and inside[loc.place] and not (opts.kind and r.kind ~= opts.kind) then
      if not loc.ended or opts.ended then
        out.here[#out.here + 1] = { id = r.id, kind = r.kind, name = r.name, place = loc.place, source = loc.source, via = loc.via }
      end
    end
  end
  return out
end

-- The place tree as text. root = a place (default: every place with no parent).
function M.tree(book, root, maxdepth)
  maxdepth = tonumber(maxdepth) or 8
  local lines = {}
  local function kids(id)
    return q("SELECT id, name FROM st_entity WHERE book = ? AND kind = 'place' AND parent = ? AND status != 'retconned' ORDER BY name",
      { book, id })
  end
  local seen = {}
  local function walk(id, name, depth)
    lines[#lines + 1] = string.rep("  ", depth) .. name .. "  [" .. id .. "]"
    if seen[id] then lines[#lines] = lines[#lines] .. "  (cycle)"; return end
    seen[id] = true
    if depth >= maxdepth then return end
    for _, k in ipairs(kids(id)) do walk(k.id, k.name, depth + 1) end
    seen[id] = nil
  end
  if root and root ~= "" then
    local e, err = ent(book, root); if not e then return nil, err end
    if not is_place(e) then return nil, e.id .. " is a " .. e.kind .. ", not a place" end
    walk(e.id, e.name, 0)
  else
    for _, r in ipairs(q([[SELECT id, name FROM st_entity WHERE book = ? AND kind = 'place' AND status != 'retconned'
                           AND (parent IS NULL OR parent = '') ORDER BY name]], { book })) do
      walk(r.id, r.name, 0)
    end
  end
  return lines
end

-- The smallest place two things share. -> { common = id|nil, a_chain, b_chain, why }
function M.between(book, a, b, t)
  local ea, e1 = ent(book, a); if not ea then return nil, e1 end
  local eb, e2 = ent(book, b); if not eb then return nil, e2 end
  local la, lb = M.where(book, ea.id, t), M.where(book, eb.id, t)
  if not la.place or not lb.place then
    return { verdict = M.UNKNOWN, why = "no location recorded for " .. (not la.place and ea.name or eb.name) }
  end
  local inb = {}
  for _, c in ipairs(lb.chain) do inb[c] = true end
  for _, c in ipairs(la.chain) do
    if inb[c] then
      local cn = names(book, { c })[1]
      return { verdict = M.TRUE, common = c, a_chain = la.chain, b_chain = lb.chain,
        why = string.format("%s and %s are both within %s", ea.name, eb.name, cn) }
    end
  end
  return { verdict = M.FALSE, a_chain = la.chain, b_chain = lb.chain,
    why = string.format("%s (%s) and %s (%s) share no container", ea.name, chain_text(book, la.chain), eb.name, chain_text(book, lb.chain)) }
end

-- ---- distance and travel -----------------------------------------------------------------------
local function haversine(lat1, lon1, lat2, lon2)
  local r = math.rad
  local dlat, dlon = r(lat2 - lat1), r(lon2 - lon1)
  local h = math.sin(dlat / 2) ^ 2 + math.cos(r(lat1)) * math.cos(r(lat2)) * math.sin(dlon / 2) ^ 2
  return 2 * M.EARTH_KM * math.asin(math.min(1, math.sqrt(h)))
end
M.haversine = haversine

-- The place (itself or the nearest container) that carries geography data.
local function anchor(book, id)
  local cur, seen = sm.entity(book, id), {}
  while cur and not seen[cur.id] do
    seen[cur.id] = true
    local a = attrs_of(cur)
    if (a.lat ~= nil and a.lon ~= nil) or (type(a.routes) == "table" and #a.routes > 0) then return cur, a end
    cur = (cur.parent and cur.parent ~= "") and sm.entity(book, cur.parent) or nil
  end
  return nil
end

function M.distance(book, a, b)
  local ea, e1 = ent(book, a); if not ea then return nil, e1 end
  local eb, e2 = ent(book, b); if not eb then return nil, e2 end
  local pa, aa = anchor(book, ea.id)
  local pb, ab = anchor(book, eb.id)
  if not (pa and pb and aa.lat ~= nil and ab.lat ~= nil) then
    return { verdict = M.UNKNOWN, why = "need lat/lon on " .. ea.name .. " and " .. eb.name .. " (or a container of each): geo set name= lat= lon=" }
  end
  local km = haversine(tonumber(aa.lat), tonumber(aa.lon), tonumber(ab.lat), tonumber(ab.lon))
  return { verdict = M.TRUE, km = km, from = pa.id, to = pb.id,
    why = string.format("%.0f km straight line from %s to %s", km, pa.name, pb.name) }
end

-- Declared routes between every place that has some: { id -> { {to, days, mode} } }.
local function graph(book)
  local g = {}
  local function edge(a, b, days, mode)
    g[a] = g[a] or {}
    g[a][#g[a] + 1] = { to = b, days = days, mode = mode }
  end
  for _, r in ipairs(q("SELECT id, attrs FROM st_entity WHERE book = ? AND kind = 'place' AND status != 'retconned'", { book })) do
    local a = attrs_of(r)
    for _, rt in ipairs(type(a.routes) == "table" and a.routes or {}) do
      local days = tonumber(rt.days)
      if rt.to and days and days >= 0 then
        edge(r.id, rt.to, days, rt.mode)
        if not rt.one_way then edge(rt.to, r.id, days, rt.mode) end
      end
    end
  end
  return g
end

-- Shortest declared route in days. -> { days, path = {place ids}, modes = {...} } | nil
function M.shortest(book, from_id, to_id)
  if from_id == to_id then return { days = 0, path = { from_id }, modes = {} } end
  local g = graph(book)
  local dist, prev, done = { [from_id] = 0 }, {}, {}
  while true do
    local cur, best
    for id, d in pairs(dist) do
      if not done[id] and (best == nil or d < best) then cur, best = id, d end
    end
    if not cur then break end
    if cur == to_id then break end
    done[cur] = true
    for _, e in ipairs(g[cur] or {}) do
      local nd = best + e.days
      if dist[e.to] == nil or nd < dist[e.to] then dist[e.to] = nd; prev[e.to] = { from = cur, mode = e.mode } end
    end
  end
  if dist[to_id] == nil then return nil end
  local path, modes, cur = {}, {}, to_id
  while cur do
    table.insert(path, 1, cur)
    local p = prev[cur]
    if p then table.insert(modes, 1, p.mode or "") end
    cur = p and p.from
  end
  return { days = dist[to_id], path = path, modes = modes }
end

-- Minimum days from one place to another, between their geography anchors.
-- -> { verdict, days, how, path } ; unknown when the book gives no way to tell.
function M.travel_time(book, a, b, opts)
  opts = opts or {}
  local ea, e1 = ent(book, a); if not ea then return nil, e1 end
  local eb, e2 = ent(book, b); if not eb then return nil, e2 end
  local pa = anchor(book, ea.id)
  local pb = anchor(book, eb.id)
  if pa and pb and pa.id == pb.id then
    return { verdict = M.TRUE, days = 0, how = "same area (" .. pa.name .. ")", from = pa.id, to = pb.id }
  end
  -- places with no geography at all but one inside the other: a local trip
  if not (pa and pb) then
    local ins = M.inside(book, ea.id, eb.id)
    local rev = M.inside(book, eb.id, ea.id)
    if (ins and ins.verdict == M.TRUE) or (rev and rev.verdict == M.TRUE) then
      return { verdict = M.TRUE, days = 0, how = "one is inside the other" }
    end
    return { verdict = M.UNKNOWN, why = "no routes or coordinates for " .. (not pa and ea.name or eb.name)
      .. ": geo set name= route_to= days=  (or lat= lon=)" }
  end
  local route = M.shortest(book, pa.id, pb.id)
  if route then
    return { verdict = M.TRUE, days = route.days, how = "declared route", path = route.path, modes = route.modes,
      from = pa.id, to = pb.id }
  end
  local d = M.distance(book, pa.id, pb.id)
  local speed = tonumber(opts.speed) or 0
  if d and d.km and speed > 0 then
    return { verdict = M.TRUE, days = d.km / speed, how = string.format("straight line at %g km/day (a lower bound)", speed),
      km = d.km, from = pa.id, to = pb.id, estimate = true }
  end
  if d and d.km then
    return { verdict = M.UNKNOWN, km = d.km, why = string.format("%.0f km apart but no declared route; pass speed= (km per day) for a lower bound", d.km) }
  end
  return { verdict = M.UNKNOWN, why = "no declared route between " .. pa.name .. " and " .. pb.name }
end

-- Can `who` be at `to_place` at t2 having been at `from_place` at t1?
-- t is in days unless per_day= says how many t-units make a day.
function M.travel_check(book, from_place, to_place, t1, t2, opts)
  opts = opts or {}
  local per_day = tonumber(opts.per_day) or 1
  t1, t2 = tonumber(t1), tonumber(t2)
  if not (t1 and t2) then return nil, "travel needs t1= and t2=" end
  local tt, err = M.travel_time(book, from_place, to_place, opts)
  if not tt then return nil, err end
  local gap_days = (t2 - t1) / per_day
  tt.gap_days = gap_days
  if tt.verdict ~= M.TRUE then return tt end
  if gap_days + 1e-9 >= tt.days then
    tt.verdict = M.TRUE
    tt.why = string.format("%.2f days available, %.2f needed (%s)", gap_days, tt.days, tt.how)
  else
    tt.verdict = M.FALSE
    tt.why = string.format("only %.2f days between t=%s and t=%s, but the journey takes at least %.2f (%s)",
      gap_days, tostring(t1), tostring(t2), tt.days, tt.how)
  end
  return tt
end

-- ---- claims --------------------------------------------------------------------------------------
-- Split "<subject> <verb> <object>" on the verb; names can be several words.
local VERBS = {
  { " is inside ", "inside" }, { " is within ", "inside" }, { " is in ", "inside" }, { " is at ", "inside" },
  { " inside ", "inside" }, { " within ", "inside" }, { " in ", "inside" }, { " at ", "inside" },
  { " holds ", "holds" }, { " has ", "holds" }, { " carries ", "holds" }, { " owns ", "holds" },
  { " knows ", "knows" },
}

local function find_event(book, ev)
  if not ev or not ev.event then return nil end
  return { event = ev.event, t = ev.t, summary = ev.summary }
end

-- parse(text) -> { kind, subject, object, field, value, op } | nil, err
function M.parse_claim(text)
  local s = " " .. tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ") .. " "
  local low = s:lower()
  -- "<x> alive" / "<x> dead"
  local who, state = low:match("^ (.-) (alive) $")
  if not who then who, state = low:match("^ (.-) (dead) $") end
  if not who then who, state = low:match("^ (.-) (ended) $") end
  if who then
    local orig = s:sub(2, 1 + #who)
    return { kind = "alive", subject = orig, want = (state == "alive") }
  end
  -- "<x> <field> <op> <value>"  (mood=calm, trust >= 3)
  local sub, field, op, val = s:match("^ (.-) ([%w_]+) ?([=<>!]=?) ?(.-) $")
  if sub and field and op and val and val ~= "" and not low:find(" in ", 1, true) and not low:find(" holds ", 1, true) then
    return { kind = "field", subject = sub, field = field, op = op, value = val }
  end
  for _, v in ipairs(VERBS) do
    local i = low:find(v[1], 1, true)
    if i then
      local subj = s:sub(2, i - 1)
      local obj = s:sub(i + #v[1], #s - 1)
      if subj ~= "" and obj ~= "" then return { kind = v[2], subject = subj, object = obj } end
    end
  end
  return nil, "cannot read the claim '" .. tostring(text) .. "' (try: 'vera in paris', 'vera holds key', 'moth alive', 'vera mood=calm', 'vera knows F3')"
end

local function cmp(op, a, b)
  local na, nb = tonumber(a), tonumber(b)
  if na and nb then
    if op == "=" or op == "==" then return na == nb elseif op == "!=" then return na ~= nb
    elseif op == ">" then return na > nb elseif op == "<" then return na < nb
    elseif op == ">=" then return na >= nb elseif op == "<=" then return na <= nb end
  end
  if op == "=" or op == "==" then return tostring(a) == tostring(b) end
  if op == "!=" then return tostring(a) ~= tostring(b) end
  return nil
end

-- check(book, claim | {kind=,...}, t) -> { verdict, why, evidence }
function M.claim(book, c, t, opts)
  opts = opts or {}
  if type(c) == "string" then
    local p, e = M.parse_claim(c); if not p then return nil, e end
    c = p
  end
  local sub, e1 = ent(book, c.subject); if not sub then return nil, e1 end
  local out = { subject = sub.id, kind = c.kind }
  if c.kind == "inside" then
    local r, e = M.inside(book, sub.id, c.object, t); if not r then return nil, e end
    return r
  elseif c.kind == "holds" then
    local item, e2 = ent(book, c.object); if not item then return nil, e2 end
    local w = M.world_at(book, t)
    local h = w.holder[item.id]
    if h == sub.id then
      return { verdict = M.TRUE, evidence = find_event(book, w.held_by[item.id]),
        why = sub.name .. " holds " .. item.name }
    elseif h then
      return { verdict = M.FALSE, evidence = find_event(book, w.held_by[item.id]),
        why = item.name .. " is held by " .. (sm.entity(book, h) or { name = h }).name }
    elseif w.held_by[item.id] then
      return { verdict = M.FALSE, evidence = find_event(book, w.held_by[item.id]), why = item.name .. " is held by nobody" }
    end
    return { verdict = M.UNKNOWN, why = "nothing in the book says who holds " .. item.name }
  elseif c.kind == "alive" then
    local w = M.world_at(book, t)
    local ended = w.ended[sub.id]
    local alive = ended == nil
    if c.want == alive then
      return { verdict = M.TRUE, why = sub.name .. (alive and " has not ended" or (" ended at t=" .. tostring(ended))) }
    end
    return { verdict = M.FALSE, why = sub.name .. (alive and " has not ended" or (" ended at t=" .. tostring(ended))) }
  elseif c.kind == "field" then
    local st = sm.state(book, sub.id, t)
    local cur = st.fields[c.field]
    if cur == nil then return { verdict = M.UNKNOWN, why = "no value for " .. c.field .. " on " .. sub.name } end
    local r = cmp(c.op, cur, c.value)
    if r == nil then return nil, "operator " .. tostring(c.op) .. " needs numbers" end
    return { verdict = r and M.TRUE or M.FALSE, why = string.format("%s.%s is %s", sub.name, c.field, tostring(cur)) }
  elseif c.kind == "knows" then
    local fact = sm.fact(book, c.object)
    if not fact then return nil, "no fact " .. tostring(c.object) end
    local known = sm.known(book, sub.id, t)
    for _, k in ipairs(known or {}) do
      if k.fact == fact.id then
        return { verdict = M.TRUE, why = string.format("%s learned %s (%s)", sub.name, fact.id, tostring(k.how)) }
      end
    end
    return { verdict = M.FALSE, why = sub.name .. " has not learned " .. fact.id .. " as of this point" }
  end
  return nil, "unknown claim kind " .. tostring(c.kind)
end

-- ---- audit ------------------------------------------------------------------------------------------
-- Every deterministic world check. -> { findings = { {severity, kind, entity, message, evidence} }, counts }
function M.audit(book, opts)
  opts = opts or {}
  local findings = {}
  local function add(sev, kind, entity, msg, evidence)
    findings[#findings + 1] = { severity = sev, kind = kind, entity = entity, message = msg, evidence = evidence }
  end
  local ents = {}
  for _, r in ipairs(q("SELECT * FROM st_entity WHERE book = ? AND status != 'retconned' ORDER BY id", { book })) do
    ents[r.id] = r
  end

  -- 1. the place tree
  for id, e in pairs(ents) do
    if e.parent and e.parent ~= "" then
      local p = ents[e.parent]
      if not p then
        add("error", "dangling_parent", id, e.name .. " is inside '" .. e.parent .. "', which does not exist")
      elseif e.kind == "place" and p.kind ~= "place" then
        add("error", "place_in_non_place", id, string.format("place %s is inside %s (%s), which is not a place", e.name, p.name, p.kind))
      end
    end
    if e.kind == "place" then
      local _, cyclic = M.ancestors(book, id)
      if cyclic then add("error", "place_cycle", id, e.name .. " is (indirectly) inside itself") end
    end
  end

  -- 2. geography data
  for id, e in pairs(ents) do
    if e.kind == "place" then
      local a = attrs_of(e)
      if a.lat ~= nil and (tonumber(a.lat) == nil or math.abs(tonumber(a.lat)) > 90) then
        add("error", "bad_coordinates", id, e.name .. " has latitude " .. tostring(a.lat) .. " (must be -90..90)")
      end
      if a.lon ~= nil and (tonumber(a.lon) == nil or math.abs(tonumber(a.lon)) > 180) then
        add("error", "bad_coordinates", id, e.name .. " has longitude " .. tostring(a.lon) .. " (must be -180..180)")
      end
      for _, rt in ipairs(type(a.routes) == "table" and a.routes or {}) do
        if not ents[rt.to or ""] then
          add("error", "route_to_nowhere", id, e.name .. " has a route to '" .. tostring(rt.to) .. "', which is not an entity")
        elseif ents[rt.to].kind ~= "place" then
          add("error", "route_to_non_place", id, e.name .. " has a route to " .. rt.to .. ", which is not a place")
        end
        if tonumber(rt.days) == nil or tonumber(rt.days) < 0 then
          add("error", "bad_route_days", id, e.name .. " -> " .. tostring(rt.to) .. " has days=" .. tostring(rt.days))
        end
      end
    end
  end

  -- 3. the event stream, replayed in time order
  local rows = q([[SELECT d.op, d.entity, d.target, d.n, e.t AS t, e.id AS ev, e.summary AS summary
                   FROM st_delta d JOIN st_event e ON e.book = d.book AND e.id = d.event
                   WHERE d.book = ? AND e.status = 'canon' ORDER BY e.t, e.id, d.n]], { book })
  local last_move = {}      -- entity -> {place, t, ev}
  local moves_at = {}       -- entity .. "@" .. t -> { place -> ev }
  local holder = {}         -- item -> entity
  local ended = {}          -- entity -> t
  for _, d in ipairs(rows) do
    if not ents[d.entity] then
      add("error", "dangling_entity", d.entity, string.format("event %s names '%s', which is not an entity", d.ev, d.entity))
    end
    if d.target and (d.op == "move" or d.op == "acquire" or d.op == "lose") and not ents[d.target] then
      add("error", "dangling_target", d.target, string.format("event %s names '%s', which is not an entity", d.ev, d.target))
    end
    if ended[d.entity] and d.op ~= "create" and d.op ~= "end" and d.t > ended[d.entity] then
      add("warning", "acts_after_end", d.entity, string.format("%s ended at t=%s but event %s (t=%s) has it %s",
        d.entity, tostring(ended[d.entity]), d.ev, tostring(d.t), d.op), { event = d.ev })
    end
    if d.op == "end" then ended[d.entity] = d.t
    elseif d.op == "create" then ended[d.entity] = nil
    elseif d.op == "move" then
      local tg = ents[d.target or ""]
      if tg and tg.kind ~= "place" then
        add("error", "move_to_non_place", d.entity, string.format("event %s moves %s to %s (%s), which is not a place",
          d.ev, d.entity, tg.id, tg.kind), { event = d.ev })
      end
      local key = d.entity .. "@" .. tostring(d.t)
      moves_at[key] = moves_at[key] or {}
      moves_at[key][d.target] = d.ev
      local lm = last_move[d.entity]
      if lm and tg and tg.kind == "place" and lm.place ~= d.target and d.t > lm.t then
        local r = M.travel_check(book, lm.place, d.target, lm.t, d.t, { per_day = opts.per_day, speed = opts.speed })
        if r and r.verdict == M.FALSE then
          add("error", "teleport", d.entity, string.format("%s: %s -> %s: %s", d.entity, lm.place, d.target, r.why),
            { from_event = lm.ev, to_event = d.ev })
        end
      end
      last_move[d.entity] = { place = d.target, t = d.t, ev = d.ev }
    elseif d.op == "acquire" then
      if holder[d.target] and holder[d.target] ~= d.entity then
        add("warning", "item_double_hold", d.target, string.format("%s acquires %s at t=%s while %s still holds it (event %s)",
          d.entity, d.target, tostring(d.t), holder[d.target], d.ev), { event = d.ev })
      end
      holder[d.target] = d.entity
    elseif d.op == "lose" then
      if holder[d.target] == d.entity then holder[d.target] = nil end
    end
  end
  for key, places in pairs(moves_at) do
    local n, list = 0, {}
    for p in pairs(places) do n = n + 1; list[#list + 1] = p end
    if n > 1 then
      table.sort(list)
      add("error", "two_places_at_once", key:match("^(.-)@"), string.format("%s is moved to %s at the same story time (%s)",
        key:match("^(.-)@"), table.concat(list, " and "), key:match("@(.+)$")))
    end
  end
  for item, who in pairs(holder) do
    if ended[who] then
      add("info", "held_by_ended", item, string.format("%s is still held by %s, who ended at t=%s", item, who, tostring(ended[who])))
    end
  end

  local counts = { error = 0, warning = 0, info = 0 }
  table.sort(findings, function(a, b)
    local ra = { error = 1, warning = 2, info = 3 }
    if ra[a.severity] ~= ra[b.severity] then return ra[a.severity] < ra[b.severity] end
    if a.kind ~= b.kind then return a.kind < b.kind end
    return tostring(a.entity) < tostring(b.entity)
  end)
  for _, f in ipairs(findings) do counts[f.severity] = counts[f.severity] + 1 end
  return { findings = findings, counts = counts }
end

function M.audit_text(report)
  local c = report.counts
  local out = { string.format("world audit: %d errors, %d warnings, %d notes", c.error, c.warning, c.info) }
  for _, f in ipairs(report.findings) do
    out[#out + 1] = string.format("  [%s] %s: %s", f.severity, f.kind, f.message)
  end
  if #report.findings == 0 then out[#out + 1] = "  nothing found" end
  return table.concat(out, "\n")
end

return M
