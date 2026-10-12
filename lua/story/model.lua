-- story/model.lua -- the story model: what is true in a book's world, when,
-- and who knows it. The design is docs/story-model.md; this is its core (M1).
--
-- Truth lives here, in st_* tables, and is mirrored to the book's own repo as
-- canonical JSONL (<root>/.boggart/story/*.jsonl): sorted, one record per
-- line, no volatile fields, so a change is a one-line diff and wiping
-- boggart.db loses nothing (the next call re-imports the mirror).
--
-- TWO CLOCKS. Every event has a story time `t` (when it happens in the world)
-- and a narrative position `pos` (where the book tells it). World state and a
-- character's knowledge are asked as of `t`; the READER's knowledge, and what
-- is safe to show a drafter, as of `pos`. In a book told in order they agree.
--
-- EVENT-SOURCED. Entities are never overwritten: an event carries deltas
-- (move, acquire, lose, set, relate, end) and the state of anything at `t` is
-- the replay of canon deltas up to `t`. Nothing is lost to a merge, and "what
-- was true at chapter 7" is a query.
--
-- STATUS AND SOURCE on everything: proposed | canon | retconned |
-- open_by_design, where it came from (author, interview, file:line,
-- generated), and for facts a modality (true | claimed | rumour | belief |
-- joke). Canon changes only by confirming a proposal -- except that the AUTHOR
-- typing a /story command IS the confirmation; the model calling the tool
-- always proposes (docs/story-model.md, decision 3).
local json = require("json")
local M = {}

local function db() return bog.db end
-- Times and positions are REAL columns; whole ones come back as integers so
-- "t=3" never reads "t=3.0".
local function q(sql, p)
  local rows = db():query(sql, p or {}) or {}
  for _, r in ipairs(rows) do
    for k, v in pairs(r) do
      if math.type(v) == "float" and v == math.floor(v) and math.abs(v) < 2^53 then r[k] = math.tointeger(v) end
    end
  end
  return rows
end
M.q = q
local function one(sql, p) return q(sql, p)[1] end
local function run(sql, p) return db():run(sql, p or {}) end
-- the binder walks a Lua array: a nil mid-array is unsafe, so optional values
-- travel as sentinels and NULLIF turns them back into NULL
local NONE_T, NONE_N = "", -1
local function S(v) if v == nil then return NONE_T end return tostring(v) end
local function N(v) v = tonumber(v); if v == nil then return NONE_N end return v end

M.STATUS = { proposed = true, canon = true, retconned = true, open_by_design = true, rejected = true }
M.MODALITY = { ["true"] = true, claimed = true, rumour = true, belief = true, joke = true }
M.ENTITY_KINDS = { character = true, place = true, item = true, faction = true, group = true, other = true }
M.HOW = { witnessed = true, told = true, read = true, inferred = true, rumour = true, author = true }
M.PROMISE_KINDS = { promise = true, question = true, clue = true, chekhov = true }
M.READER = "reader"

-- ---- schema ------------------------------------------------------------------------------
M.TABLES = { "st_entity", "st_alias", "st_event", "st_delta", "st_fact", "st_knows", "st_promise",
             "st_exemption", "st_proposal", "st_change", "st_seq", "st_fts" }
local ready = false
function M.ensure_schema()
  if ready then return true end
  if not (bog and bog.db) then return nil, "store not open" end
  for _, sql in ipairs{
    [[CREATE TABLE IF NOT EXISTS st_seq (book TEXT, kind TEXT, n INTEGER, PRIMARY KEY (book, kind))]],
    [[CREATE TABLE IF NOT EXISTS st_entity (book TEXT, id TEXT, kind TEXT, name TEXT, parent TEXT,
        discoverability TEXT, body TEXT, attrs TEXT, status TEXT, source TEXT, PRIMARY KEY (book, id))]],
    [[CREATE TABLE IF NOT EXISTS st_alias (book TEXT, norm TEXT, alias TEXT, entity TEXT, source TEXT,
        PRIMARY KEY (book, norm, entity))]],
    [[CREATE TABLE IF NOT EXISTS st_event (book TEXT, id TEXT, t REAL, pos REAL, scene TEXT, kind TEXT,
        summary TEXT, secret INTEGER, status TEXT, source TEXT, confidence REAL, PRIMARY KEY (book, id))]],
    [[CREATE TABLE IF NOT EXISTS st_delta (book TEXT, event TEXT, n INTEGER, op TEXT, entity TEXT,
        field TEXT, value TEXT, target TEXT, PRIMARY KEY (book, event, n))]],
    [[CREATE TABLE IF NOT EXISTS st_fact (book TEXT, id TEXT, kind TEXT, subject TEXT, body TEXT,
        visibility TEXT, status TEXT, modality TEXT, holder TEXT, valid_from REAL, valid_to REAL,
        superseded_by TEXT, withhold_until REAL, source TEXT, importance INTEGER, confidence REAL, note TEXT,
        PRIMARY KEY (book, id))]],
    [[CREATE TABLE IF NOT EXISTS st_knows (book TEXT, id TEXT, holder TEXT, fact TEXT, learned_t REAL,
        learned_pos REAL, how TEXT, from_entity TEXT, confidence REAL, version TEXT, superseded_by TEXT,
        status TEXT, source TEXT, PRIMARY KEY (book, id))]],
    [[CREATE TABLE IF NOT EXISTS st_promise (book TEXT, id TEXT, kind TEXT, body TEXT, setup TEXT,
        payoff TEXT, thread TEXT, status TEXT, due_pos REAL, source TEXT, PRIMARY KEY (book, id))]],
    [[CREATE TABLE IF NOT EXISTS st_exemption (book TEXT, id TEXT, kind TEXT, target TEXT, reason TEXT,
        PRIMARY KEY (book, id))]],
    [[CREATE TABLE IF NOT EXISTS st_proposal (book TEXT, id TEXT, grp TEXT, kind TEXT, action TEXT,
        payload TEXT, summary TEXT, evidence TEXT, origin TEXT, plan_match INTEGER, status TEXT,
        result TEXT, PRIMARY KEY (book, id))]],
    [[CREATE TABLE IF NOT EXISTS st_change (book TEXT, seq INTEGER, kind TEXT, target TEXT, before TEXT,
        after TEXT, via TEXT, PRIMARY KEY (book, seq))]],
    [[CREATE VIRTUAL TABLE IF NOT EXISTS st_fts USING fts5(book UNINDEXED, kind UNINDEXED, id UNINDEXED,
        text, tokenize = 'porter unicode61')]],
  } do run(sql) end
  ready = true
  return true
end

function M.drop_book(book)
  M.ensure_schema()
  for _, t in ipairs(M.TABLES) do run("DELETE FROM " .. t .. " WHERE book = ?", { book }) end
end

-- ---- ids, names -----------------------------------------------------------------------
local PREFIX = { fact = "F", event = "E", knows = "K", promise = "P", exemption = "X", proposal = "Q", change = "" }
local function next_id(book, kind)
  local r = one("SELECT n FROM st_seq WHERE book = ? AND kind = ?", { book, kind })
  local n = (r and r.n or 0) + 1
  run("INSERT OR REPLACE INTO st_seq(book, kind, n) VALUES(?,?,?)", { book, kind, n })
  return (PREFIX[kind] or "") .. n, n
end
M.next_id = next_id

-- An alias as it is matched: case-folded, punctuation and a leading article
-- dropped, spaces collapsed. "The Red Door" and "red door" are one alias.
function M.norm(s)
  -- curly quotes are multi-byte: replace them as strings, never inside a [class]
  s = tostring(s or ""):lower():gsub("\u{2019}", "'"):gsub("\u{2018}", "'")
  s = s:gsub("'s%f[%A]", ""):gsub("[%p]", " "):gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^the ", "")
  return s
end

-- A readable, stable id from a name: "Vera Lind" -> "vera-lind".
function M.slug(s)
  local out = M.norm(s):gsub("%s", "-")
  return out ~= "" and out or "x"
end

local function fts_put(book, kind, id, text)
  run("DELETE FROM st_fts WHERE book = ? AND kind = ? AND id = ?", { book, kind, id })
  if text and text:match("%S") then run("INSERT INTO st_fts(book, kind, id, text) VALUES(?,?,?,?)", { book, kind, id, text }) end
end

local function log_change(book, kind, target, before, after, via)
  local _, n = next_id(book, "change")
  run("INSERT INTO st_change(book, seq, kind, target, before, after, via) VALUES(?,?,?,?,?,?,?)",
    { book, n, kind, target, before and json.encode(before) or "", after and json.encode(after) or "", via or "" })
end

-- ---- entities + aliases -----------------------------------------------------------------------
function M.entity(book, id) return one("SELECT * FROM st_entity WHERE book = ? AND id = ?", { book, id }) end

-- -> list of entity rows an alias (or id) could mean. Exact alias first; the
-- caller decides what to do with several (the model is asked; a person picks).
function M.resolve(book, name)
  if not name or name == "" then return {} end
  local e = M.entity(book, name)
  if e then return { e } end
  local out, seen = {}, {}
  for _, r in ipairs(q([[SELECT e.* FROM st_alias a JOIN st_entity e ON e.book = a.book AND e.id = a.entity
                         WHERE a.book = ? AND a.norm = ? AND e.status != 'retconned' ORDER BY e.id]], { book, M.norm(name) })) do
    if not seen[r.id] then seen[r.id] = true; out[#out + 1] = r end
  end
  return out
end

-- The one entity a name means, or nil and why (none, or ambiguous).
function M.resolve1(book, name)
  local rs = M.resolve(book, name)
  if #rs == 1 then return rs[1] end
  if #rs == 0 then return nil, "no entity called '" .. tostring(name) .. "'" end
  local ids = {}
  for _, r in ipairs(rs) do ids[#ids + 1] = r.id end
  return nil, "'" .. name .. "' could mean " .. table.concat(ids, ", ") .. " -- use the id"
end

function M.add_alias(book, entity, alias, source)
  local n = M.norm(alias)
  if n == "" then return nil, "empty alias" end
  run("INSERT OR IGNORE INTO st_alias(book, norm, alias, entity, source) VALUES(?,?,?,?,?)",
    { book, n, alias, entity, source or "author" })
  local e = M.entity(book, entity)
  if e then
    local names = {}
    for _, a in ipairs(q("SELECT alias FROM st_alias WHERE book = ? AND entity = ?", { book, entity })) do names[#names + 1] = a.alias end
    fts_put(book, "entity", entity, e.name .. "\n" .. table.concat(names, ", ") .. "\n" .. (e.body or ""))
  end
  return true
end

-- Resolution BEFORE insert (the HPMOR lesson: three Harrys). A new entity
-- whose name or any alias already names another entity of the same kind is
-- refused; say `alias=` to add to the existing one, or `distinct=true` when
-- two people really share a name.
function M.add_entity(book, e, via)
  if not M.ENTITY_KINDS[e.kind or ""] then return nil, "kind must be character|place|item|faction|group|other" end
  if not e.name or e.name == "" then return nil, "an entity needs a name" end
  local id = e.id or M.slug(e.name)
  if e.id and M.entity(book, id) then return nil, "entity " .. id .. " already exists" end
  -- an id is a handle, never a name someone else answers to: "vera" for a
  -- second Vera would silently resolve to the wrong one, so it becomes vera-2
  local base, n = id, 1
  while M.entity(book, id) or one("SELECT 1 AS x FROM st_alias WHERE book = ? AND norm = ?", { book, M.norm(id:gsub("%-", " ")) }) do
    n = n + 1
    id = base .. "-" .. n
  end
  if not e.distinct then
    for _, nm in ipairs({ e.name, table.unpack(e.aliases or {}) }) do
      for _, r in ipairs(M.resolve(book, nm)) do
        if r.kind == e.kind then
          return nil, string.format("'%s' already names %s (%s) -- add it as an alias of that, or pass distinct=true", nm, r.id, r.name)
        end
      end
    end
  end
  if e.parent and e.parent ~= "" and not M.entity(book, e.parent) then
    local p, pe = M.resolve1(book, e.parent)
    if not p then return nil, "parent: " .. pe end
    e.parent = p.id
  end
  run([[INSERT INTO st_entity(book,id,kind,name,parent,discoverability,body,attrs,status,source)
        VALUES(?,?,?,?,NULLIF(?,''),?,?,?,?,?)]],
    { book, id, e.kind, e.name, S(e.parent), e.discoverability or "public", e.body or "",
      json.encode(e.attrs or {}), e.status or "canon", e.source or via or "author" })
  M.add_alias(book, id, e.name, "name")
  for _, a in ipairs(e.aliases or {}) do M.add_alias(book, id, a, e.source or "author") end
  log_change(book, "entity", id, nil, e, via)
  return id
end

function M.update_entity(book, id, fields, via)
  local e = M.entity(book, id)
  if not e then return nil, "no entity " .. tostring(id) end
  local before = { name = e.name, body = e.body, parent = e.parent, discoverability = e.discoverability }
  local attrs = json.decode(e.attrs or "{}")
  for k, v in pairs(fields.attrs or {}) do attrs[k] = v end
  run([[UPDATE st_entity SET name = ?, body = ?, parent = NULLIF(?,''), discoverability = ?, attrs = ?
        WHERE book = ? AND id = ?]],
    { fields.name or e.name, fields.body or e.body, S(fields.parent or e.parent),
      fields.discoverability or e.discoverability, json.encode(attrs), book, id })
  if fields.name and fields.name ~= e.name then M.add_alias(book, id, fields.name, "name") end
  M.add_alias(book, id, fields.name or e.name, "name")
  log_change(book, "entity", id, before, fields, via)
  return id
end

-- ---- events + deltas ---------------------------------------------------------------------------
-- A delta in a line of text, so an author (or a model) can write them plainly:
--   move vera to titan-station     vera moves to titan-station
--   vera acquires key              vera loses key
--   vera status=wounded            (any field=value)
--   relate vera moth trust +2      relate vera moth trust =5    (relations are numbers)
--   end moth                       (dies / destroyed / leaves the story)
--   create lamp                    (enters the story here)
function M.parse_delta(line)
  local l = line:gsub("^%s+", ""):gsub("%s+$", "")
  local a, b = l:match("^move%s+(.-)%s+to%s+(.+)$")
  if a then return { op = "move", entity = a, target = b } end
  a, b = l:match("^(.-)%s+moves%s+to%s+(.+)$")
  if a then return { op = "move", entity = a, target = b } end
  a, b = l:match("^(.-)%s+acquires%s+(.+)$")
  if a then return { op = "acquire", entity = a, target = b } end
  a, b = l:match("^(.-)%s+loses%s+(.+)$")
  if a then return { op = "lose", entity = a, target = b } end
  local x, y, f, v = l:match("^relate%s+(%S+)%s+(%S+)%s+([%w_]+)%s+([%+%-=]?%-?[%d%.]+)$")
  if x then return { op = "relate", entity = x, target = y, field = f, value = v } end
  a = l:match("^end%s+(.+)$")
  if a then return { op = "end", entity = a } end
  a = l:match("^create%s+(.+)$")
  if a then return { op = "create", entity = a } end
  a, f, v = l:match("^(%S+)%s+([%w_]+)%s*=%s*(.+)$")
  if a then return { op = "set", entity = a, field = f, value = v } end
  return nil, "cannot read delta '" .. l .. "' (move X to Y | X acquires Y | X loses Y | X field=value | "
    .. "relate X Y field +n | end X | create X)"
end

function M.split_deltas(s)
  local out = {}
  for part in (tostring(s or "") .. ";"):gmatch("(.-)[;\n]") do
    if part:match("%S") then out[#out + 1] = part end
  end
  return out
end

-- -> event id, warnings | nil, err. Deltas name entities by id or alias; they
-- are resolved (and refused if ambiguous) before anything is written, and the
-- event is checked against the world as of `t` (a dead man moving, an item
-- someone else holds): problems come back as warnings, not refusals -- a
-- flashback or an unreliable narrator may mean exactly that.
function M.add_event(book, ev, via)
  local t = tonumber(ev.t)
  if not t then return nil, "an event needs t= (story time)" end
  local pos = tonumber(ev.pos) or t
  local deltas = {}
  for _, line in ipairs(type(ev.deltas) == "table" and ev.deltas or M.split_deltas(ev.deltas)) do
    local d, de = type(line) == "table" and line or M.parse_delta(line)
    if not d then return nil, de end
    local e, ee = M.resolve1(book, d.entity)
    if not e then return nil, ee end
    d.entity = e.id
    if d.op == "move" or d.op == "acquire" or d.op == "lose" or d.op == "relate" then
      local tg, te = M.resolve1(book, d.target)
      if not tg then return nil, te end
      d.target = tg.id
    end
    deltas[#deltas + 1] = d
  end
  -- checks against the world as it stands at t
  local warnings = {}
  for _, d in ipairs(deltas) do
    local st = M.state(book, d.entity, t)
    if st.ended and d.op ~= "create" then
      warnings[#warnings + 1] = d.entity .. " has ended (at t=" .. tostring(st.ended) .. ") before t=" .. t
    end
    if d.op == "acquire" then
      local holder = M.holder(book, d.target, t)
      if holder and holder ~= d.entity then
        warnings[#warnings + 1] = d.target .. " is held by " .. holder .. " at t=" .. t .. " (add: " .. holder .. " loses " .. d.target .. ")"
      end
    elseif d.op == "lose" then
      local holder = M.holder(book, d.target, t)
      if holder ~= d.entity then warnings[#warnings + 1] = d.entity .. " does not hold " .. d.target .. " at t=" .. t end
    end
  end
  local id = ev.id or next_id(book, "event")
  run([[INSERT INTO st_event(book,id,t,pos,scene,kind,summary,secret,status,source,confidence)
        VALUES(?,?,?,?,NULLIF(?,''),?,?,?,?,?,?)]],
    { book, id, t, pos, S(ev.scene), ev.kind or "event", ev.summary or "", ev.secret and 1 or 0,
      ev.status or "canon", ev.source or via or "author", tonumber(ev.confidence) or 1 })
  for i, d in ipairs(deltas) do
    run([[INSERT INTO st_delta(book,event,n,op,entity,field,value,target) VALUES(?,?,?,?,?,NULLIF(?,''),NULLIF(?,''),NULLIF(?,''))]],
      { book, id, i, d.op, d.entity, S(d.field), S(d.value), S(d.target) })
  end
  fts_put(book, "event", id, ev.summary or "")
  log_change(book, "event", id, nil, { t = t, pos = pos, summary = ev.summary, deltas = deltas }, via)
  return id, warnings
end

-- ---- state as of t: the replay ----------------------------------------------------------------------
local function canon_deltas(book, upto_t, entity)
  local sql = [[SELECT d.*, e.t AS t, e.id AS ev FROM st_delta d JOIN st_event e ON e.book = d.book AND e.id = d.event
                WHERE d.book = ? AND e.status = 'canon' AND e.t <= ?]]
  local p = { book, upto_t }
  if entity then sql = sql .. " AND (d.entity = ? OR d.target = ?)"; p[#p + 1] = entity; p[#p + 1] = entity end
  return q(sql .. " ORDER BY e.t, e.id, d.n", p)
end

-- -> { id, place, ended, fields = {k=v}, holds = {item=true}, relations = {other={field=n}},
--      history = { {t, event, op, ...} } }
function M.state(book, id, t)
  t = tonumber(t) or math.huge
  local st = { id = id, fields = {}, holds = {}, relations = {}, history = {} }
  for _, d in ipairs(canon_deltas(book, t, id)) do
    if d.entity == id then
      if d.op == "move" then st.place = d.target
      elseif d.op == "acquire" then st.holds[d.target] = true
      elseif d.op == "lose" then st.holds[d.target] = nil
      elseif d.op == "set" then st.fields[d.field] = d.value
      elseif d.op == "end" then st.ended = d.t
      elseif d.op == "create" then st.created = d.t; st.ended = nil
      elseif d.op == "relate" then
        local r = st.relations[d.target] or {}
        local cur = r[d.field] or 0
        local sign, num = d.value:match("^([%+%-=]?)(%-?[%d%.]+)$")
        num = tonumber(num) or 0
        if sign == "=" then r[d.field] = num elseif sign == "-" then r[d.field] = cur - num else r[d.field] = cur + num end
        st.relations[d.target] = r
      end
    elseif d.target == id and d.op == "relate" then
      -- relations are symmetric unless the book says otherwise
      local r = st.relations[d.entity] or {}
      local cur = r[d.field] or 0
      local sign, num = d.value:match("^([%+%-=]?)(%-?[%d%.]+)$")
      num = tonumber(num) or 0
      if sign == "=" then r[d.field] = num elseif sign == "-" then r[d.field] = cur - num else r[d.field] = cur + num end
      st.relations[d.entity] = r
    elseif d.target == id and d.op == "move" then
      -- someone arrived here: not this entity's state, but its history
    end
    st.history[#st.history + 1] = { t = d.t, event = d.ev, op = d.op, entity = d.entity, target = d.target,
                                    field = d.field, value = d.value }
  end
  local items = {}
  for k in pairs(st.holds) do items[#items + 1] = k end
  table.sort(items)
  st.items = items
  return st
end

-- Who holds an item at t (the last acquire not followed by a lose).
function M.holder(book, item, t)
  local h
  for _, d in ipairs(canon_deltas(book, tonumber(t) or math.huge, item)) do
    if d.target == item and d.op == "acquire" then h = d.entity
    elseif d.target == item and d.op == "lose" and d.entity == h then h = nil end
  end
  return h
end

-- Who is at a place at t (their last move).
function M.present(book, place, t)
  local where = {}
  for _, d in ipairs(canon_deltas(book, tonumber(t) or math.huge)) do
    if d.op == "move" then where[d.entity] = d.target end
    if d.op == "end" then where[d.entity] = nil end
  end
  local out = {}
  for who, p in pairs(where) do if p == place then out[#out + 1] = who end end
  table.sort(out)
  return out
end

-- ---- facts ----------------------------------------------------------------------------------------
function M.fact(book, id) return one("SELECT * FROM st_fact WHERE book = ? AND id = ?", { book, id }) end

function M.add_fact(book, f, via)
  if not f.body or not f.body:match("%S") then return nil, "a fact needs body=" end
  local modality = f.modality or "true"
  if not M.MODALITY[modality] then return nil, "modality must be true|claimed|rumour|belief|joke" end
  if (modality == "claimed" or modality == "belief") and not f.holder then
    return nil, "a " .. modality .. " fact needs holder= (who claims or believes it)"
  end
  local subject = f.subject
  if subject and subject ~= "" then
    local e, ee = M.resolve1(book, subject)
    if not e then return nil, "subject: " .. ee end
    subject = e.id
  end
  local holder = f.holder
  if holder and holder ~= "" then
    local e, ee = M.resolve1(book, holder)
    if not e then return nil, "holder: " .. ee end
    holder = e.id
  end
  local status = f.status or "canon"
  if not M.STATUS[status] then return nil, "bad status " .. status end
  local id = f.id or next_id(book, "fact")
  run([[INSERT INTO st_fact(book,id,kind,subject,body,visibility,status,modality,holder,valid_from,valid_to,
        superseded_by,withhold_until,source,importance,confidence,note)
        VALUES(?,?,?,NULLIF(?,''),?,?,?,?,NULLIF(?,''),NULLIF(?,-1),NULLIF(?,-1),NULLIF(?,''),NULLIF(?,-1),?,?,?,?)]],
    { book, id, f.kind or "lore", S(subject), f.body, f.visibility or "public", status, modality, S(holder),
      N(f.valid_from), N(f.valid_to), S(f.superseded_by), N(f.withhold_until), f.source or via or "author",
      tonumber(f.importance) or 3, tonumber(f.confidence) or 1, f.note or "" })
  fts_put(book, "fact", id, f.body)
  log_change(book, "fact", id, nil, f, via)
  return id
end

-- A retcon never edits the old fact: the old one is marked retconned and
-- points at its replacement, so what the book USED to say stays findable.
function M.retcon(book, old_id, fields, via)
  local old = M.fact(book, old_id)
  if not old then return nil, "no fact " .. tostring(old_id) end
  if old.status == "retconned" then return nil, old_id .. " is already retconned (by " .. tostring(old.superseded_by) .. ")" end
  local nf = {
    kind = fields.kind or old.kind, subject = fields.subject or old.subject, body = fields.body or old.body,
    visibility = fields.visibility or old.visibility, modality = fields.modality or old.modality,
    holder = fields.holder or old.holder, valid_from = fields.valid_from or old.valid_from,
    valid_to = fields.valid_to or old.valid_to, withhold_until = fields.withhold_until or old.withhold_until,
    importance = fields.importance or old.importance, source = fields.source or via or "author",
    note = fields.note or ("retcon of " .. old_id),
  }
  local id, e = M.add_fact(book, nf, via)
  if not id then return nil, e end
  run("UPDATE st_fact SET status = 'retconned', superseded_by = ? WHERE book = ? AND id = ?", { id, book, old_id })
  -- whoever knew the old fact now "knows" something that is no longer true; the
  -- knowledge rows stay (they are history) -- detectors may flag them.
  log_change(book, "retcon", old_id, { status = old.status }, { status = "retconned", superseded_by = id }, via)
  return id
end

-- Canon facts in force at story time t: canon, not superseded, inside their
-- validity window. `opts.pos` also drops facts withheld until later in the
-- telling (the twist stays out of a drafting packet until its chapter).
function M.facts_at(book, t, opts)
  opts = opts or {}
  t = tonumber(t) or math.huge
  local sql = [[SELECT * FROM st_fact WHERE book = ? AND status = 'canon'
                AND (valid_from IS NULL OR valid_from <= ?) AND (valid_to IS NULL OR valid_to > ?)]]
  local p = { book, t, t }
  if opts.pos then sql = sql .. " AND (withhold_until IS NULL OR withhold_until <= ?)"; p[#p + 1] = tonumber(opts.pos) end
  if opts.subject then sql = sql .. " AND subject = ?"; p[#p + 1] = opts.subject end
  if opts.visibility then sql = sql .. " AND visibility = ?"; p[#p + 1] = opts.visibility end
  return q(sql .. " ORDER BY importance DESC, id", p)
end

-- ---- knowledge ------------------------------------------------------------------------------------
-- `holder` is a character (learned at story time t) or "reader" (learned at
-- narrative position pos).
function M.add_knows(book, k, via)
  local holder = k.holder
  if holder ~= M.READER then
    local e, ee = M.resolve1(book, holder)
    if not e then return nil, "holder: " .. ee end
    holder = e.id
  end
  local f = M.fact(book, k.fact or "")
  if not f then return nil, "no fact " .. tostring(k.fact) end
  local how = k.how or "witnessed"
  if not M.HOW[how] then return nil, "how must be witnessed|told|read|inferred|rumour|author" end
  local from = k.from
  if from and from ~= "" then
    local e, ee = M.resolve1(book, from)
    if not e then return nil, "from: " .. ee end
    from = e.id
  end
  local lt, lp = tonumber(k.t), tonumber(k.pos)
  if holder == M.READER then
    if not lp then return nil, "the reader learns at a narrative position: pos=" end
  elseif not lt then
    return nil, "a character learns at a story time: t="
  end
  local id = k.id or next_id(book, "knows")
  run([[INSERT INTO st_knows(book,id,holder,fact,learned_t,learned_pos,how,from_entity,confidence,version,
        superseded_by,status,source) VALUES(?,?,?,?,NULLIF(?,-1),NULLIF(?,-1),?,NULLIF(?,''),?,?,NULL,?,?)]],
    { book, id, holder, f.id, N(lt), N(lp), how, S(from), tonumber(k.confidence) or 1, k.version or "",
      k.status or "canon", k.source or via or "author" })
  if k.version and k.version ~= "" then fts_put(book, "knows", id, k.version) end
  log_change(book, "knows", id, nil, { holder = holder, fact = f.id, t = lt, pos = lp, how = how }, via)
  return id
end

-- What `holder` knows as of t (a character) or pos (the reader).
function M.known(book, holder, at)
  at = tonumber(at) or math.huge
  local col = holder == M.READER and "learned_pos" or "learned_t"
  return q([[SELECT k.*, f.body AS fact_body, f.subject AS subject, f.status AS fact_status, f.visibility AS visibility
             FROM st_knows k JOIN st_fact f ON f.book = k.book AND f.id = k.fact
             WHERE k.book = ? AND k.holder = ? AND k.status = 'canon' AND k.]] .. col .. [[ <= ?
             ORDER BY k.]] .. col .. ", k.id", { book, holder, at })
end

-- Facts `holder` does NOT know as of `at`: canon SECRET facts (and, with
-- opts.subjects, any facts about those entities) they have not learned. This is
-- the leak guard a drafting packet carries: "Moth does not yet know ...".
function M.unknown(book, holder, at, opts)
  opts = opts or {}
  local knows = {}
  for _, k in ipairs(M.known(book, holder, at)) do knows[k.fact] = true end
  local t = (holder == M.READER) and math.huge or at
  local out = {}
  for _, f in ipairs(M.facts_at(book, t)) do
    local about = opts.subjects and f.subject and opts.subjects[f.subject]
    if not knows[f.id] and (f.visibility == "secret" or about) then out[#out + 1] = f end
  end
  return out
end

-- Who knows a fact, and since when.
function M.who_knows(book, fact_id, at)
  at = tonumber(at) or math.huge
  return q([[SELECT * FROM st_knows WHERE book = ? AND fact = ? AND status = 'canon'
             AND ((holder = 'reader' AND learned_pos <= ?) OR (holder != 'reader' AND learned_t <= ?))
             ORDER BY COALESCE(learned_t, learned_pos), id]], { book, fact_id, at, at })
end

-- ---- promises, exemptions ------------------------------------------------------------------------
function M.add_promise(book, p, via)
  if not M.PROMISE_KINDS[p.kind or "promise"] then return nil, "kind must be promise|question|clue|chekhov" end
  if not p.body or not p.body:match("%S") then return nil, "a promise needs body=" end
  local id = p.id or next_id(book, "promise")
  run([[INSERT INTO st_promise(book,id,kind,body,setup,payoff,thread,status,due_pos,source)
        VALUES(?,?,?,?,NULLIF(?,''),NULLIF(?,''),NULLIF(?,''),?,NULLIF(?,-1),?)]],
    { book, id, p.kind or "promise", p.body, S(p.setup), S(p.payoff), S(p.thread), p.status or "open",
      N(p.due_pos), p.source or via or "author" })
  fts_put(book, "promise", id, p.body)
  log_change(book, "promise", id, nil, p, via)
  return id
end

function M.pay_promise(book, id, payoff, via)
  local p = one("SELECT * FROM st_promise WHERE book = ? AND id = ?", { book, id })
  if not p then return nil, "no promise " .. tostring(id) end
  run("UPDATE st_promise SET payoff = ?, status = 'paid' WHERE book = ? AND id = ?", { payoff or "", book, id })
  log_change(book, "promise", id, { status = p.status }, { status = "paid", payoff = payoff }, via)
  return id
end

function M.add_exemption(book, x, via)
  if not x.reason or x.reason == "" then return nil, "an exemption needs reason=" end
  local id = next_id(book, "exemption")
  run("INSERT INTO st_exemption(book,id,kind,target,reason) VALUES(?,?,?,?,?)",
    { book, id, x.kind or "any", x.target or "", x.reason })
  log_change(book, "exemption", id, nil, x, via)
  return id
end

-- ---- proposals: the only way the model changes canon ------------------------------------------------
-- kind + action + payload is exactly a call that would be made directly;
-- accepting runs it (via "proposal:Qn"). `evidence` = { path, line, quote }:
-- a quote that cannot be found in the file at propose time is refused -- an
-- extraction that cannot point at its source is not evidence.
M.APPLY = {}
function M.propose(book, pr, root)
  if not pr.kind or not M.APPLY[pr.kind .. "." .. (pr.action or "add")] then
    return nil, "cannot propose " .. tostring(pr.kind) .. "." .. tostring(pr.action)
  end
  local ev = pr.evidence
  if ev and ev.quote and ev.path and root then
    local full = ev.path:sub(1, 1) == "/" and ev.path or (root .. "/" .. ev.path)
    local f = io.open(full, "rb")
    local text = f and f:read("a") or ""
    if f then f:close() end
    local norm = function(s)
      s = s:gsub("\u{2018}", "'"):gsub("\u{2019}", "'"):gsub("\u{201C}", '"'):gsub("\u{201D}", '"')
      return (s:gsub("%s+", " "))
    end
    if not norm(text):find(norm(ev.quote), 1, true) then
      return nil, "evidence quote not found in " .. ev.path .. ": \"" .. ev.quote:sub(1, 80) .. "\""
    end
  end
  local id = next_id(book, "proposal")
  run([[INSERT INTO st_proposal(book,id,grp,kind,action,payload,summary,evidence,origin,plan_match,status,result)
        VALUES(?,?,?,?,?,?,?,?,?,?,'pending','')]],
    { book, id, pr.grp or "", pr.kind, pr.action or "add", json.encode(pr.payload or {}), pr.summary or "",
      ev and json.encode(ev) or "", pr.origin or "model", pr.plan_match and 1 or 0 })
  return id
end

-- Which proposals a selector means: ids="Q1,Q3", group=, or all=true (pending).
function M.select_proposals(book, sel)
  sel = sel or {}
  if sel.ids and sel.ids ~= "" then
    local out = {}
    for id in tostring(sel.ids):gmatch("[^,%s]+") do
      local r = one("SELECT * FROM st_proposal WHERE book = ? AND id = ?", { book, id:upper() })
      if r then out[#out + 1] = r end
    end
    return out
  end
  local sql, p = "SELECT * FROM st_proposal WHERE book = ? AND status = 'pending'", { book }
  if sel.group and sel.group ~= "" then sql = sql .. " AND grp = ?"; p[#p + 1] = sel.group
  elseif not sel.all then return {} end
  return q(sql .. " ORDER BY CAST(SUBSTR(id, 2) AS INTEGER)", p)
end

-- Accept: apply each (in id order, so an entity proposed before a fact about
-- it lands first), recording what happened. One failing does not stop the rest.
function M.accept(book, rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r.status ~= "pending" then
      out[#out + 1] = r.id .. ": already " .. r.status
    else
      local fn = M.APPLY[r.kind .. "." .. r.action]
      local ok, res, e = pcall(fn, book, json.decode(r.payload), "proposal:" .. r.id)
      if ok and res then
        run("UPDATE st_proposal SET status = 'accepted', result = ? WHERE book = ? AND id = ?", { tostring(res), book, r.id })
        out[#out + 1] = r.id .. ": accepted -> " .. tostring(res)
      else
        local why = ok and tostring(e) or tostring(res)
        run("UPDATE st_proposal SET result = ? WHERE book = ? AND id = ?", { "failed: " .. why, book, r.id })
        out[#out + 1] = r.id .. ": NOT applied -- " .. why
      end
    end
  end
  return out
end

function M.reject(book, rows, reason)
  local out = {}
  for _, r in ipairs(rows) do
    if r.status == "pending" then
      run("UPDATE st_proposal SET status = 'rejected', result = ? WHERE book = ? AND id = ?", { reason or "", book, r.id })
      out[#out + 1] = r.id .. ": rejected"
    else
      out[#out + 1] = r.id .. ": already " .. r.status
    end
  end
  return out
end

M.APPLY["entity.add"] = function(book, p, via) return M.add_entity(book, p, via) end
M.APPLY["entity.update"] = function(book, p, via) return M.update_entity(book, p.id, p, via) end
M.APPLY["entity.alias"] = function(book, p, via)
  local e, ee = M.resolve1(book, p.entity)
  if not e then return nil, ee end
  local ok, ae = M.add_alias(book, e.id, p.alias, via)
  return ok and (e.id .. " += " .. p.alias) or nil, ae
end
M.APPLY["event.add"] = function(book, p, via)
  local id, w = M.add_event(book, p, via)
  if not id then return nil, w end
  return (#w > 0) and (id .. " (warnings: " .. table.concat(w, "; ") .. ")") or id
end
M.APPLY["fact.add"] = function(book, p, via) return M.add_fact(book, p, via) end
M.APPLY["fact.retcon"] = function(book, p, via) return M.retcon(book, p.id, p, via) end
M.APPLY["knows.add"] = function(book, p, via) return M.add_knows(book, p, via) end
M.APPLY["promise.add"] = function(book, p, via) return M.add_promise(book, p, via) end
M.APPLY["promise.pay"] = function(book, p, via) return M.pay_promise(book, p.id, p.payoff, via) end
M.APPLY["exemption.add"] = function(book, p, via) return M.add_exemption(book, p, via) end

-- ---- search --------------------------------------------------------------------------------------------
function M.search(book, query, kinds, mode)
  local terms = {}
  for w in tostring(query or ""):gmatch("[%w']+") do terms[#terms + 1] = '"' .. w:gsub('"', "") .. '"' end
  if #terms == 0 then return {} end
  local sql = "SELECT kind, id, text, bm25(st_fts) AS rank FROM st_fts WHERE st_fts MATCH ? AND book = ?"
  local p = { table.concat(terms, mode == "or" and " OR " or " AND "), book }
  if kinds and kinds ~= "" and kinds ~= "all" then sql = sql .. " AND kind = ?"; p[#p + 1] = kinds end
  return q(sql .. " ORDER BY rank LIMIT 30", p)
end

-- ---- the JSONL mirror ------------------------------------------------------------------------------------
-- One file per table, rows sorted by key, keys sorted within a row, no
-- volatile columns: export -> import -> export is byte-identical.
M.MIRROR = {
  { file = "entities", tbl = "st_entity", key = "id" },
  { file = "aliases", tbl = "st_alias", key = "entity, norm" },
  { file = "events", tbl = "st_event", key = "t, id" },
  { file = "deltas", tbl = "st_delta", key = "event, n" },
  { file = "facts", tbl = "st_fact", key = "id" },
  { file = "knows", tbl = "st_knows", key = "id" },
  { file = "promises", tbl = "st_promise", key = "id" },
  { file = "exemptions", tbl = "st_exemption", key = "id" },
  { file = "proposals", tbl = "st_proposal", key = "id" },
  { file = "seq", tbl = "st_seq", key = "kind" },
}

local function mirror_dir(root) return root .. "/.boggart/story" end

local function sort_ids(rows, key)
  -- ids like F2 < F10: natural order on the first key when it is an id
  if key == "id" then
    table.sort(rows, function(a, b)
      local pa, na = tostring(a.id):match("^(%a*)(%d*)$")
      local pb, nb = tostring(b.id):match("^(%a*)(%d*)$")
      if pa and pb and pa == pb and na ~= "" and nb ~= "" then return tonumber(na) < tonumber(nb) end
      return tostring(a.id) < tostring(b.id)
    end)
  end
  return rows
end

function M.export(book, root)
  local dir = mirror_dir(root)
  if sys.stat(dir) ~= "dir" then sys.mkdir_p(dir) end
  local all = {}
  for _, m in ipairs(M.MIRROR) do
    local rows = sort_ids(q("SELECT * FROM " .. m.tbl .. " WHERE book = ? ORDER BY " .. m.key, { book }), m.key)
    local lines = {}
    for _, r in ipairs(rows) do
      r.book = nil
      lines[#lines + 1] = json.encode(r)
    end
    local text = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
    all[#all + 1] = text
    local path = dir .. "/" .. m.file .. ".jsonl"
    local cur = require("story.book").read(path)
    if cur ~= text then
      if text == "" and not cur then
        -- nothing to write, nothing there
      else
        local tmp = path .. ".tmp"
        local f = assert(io.open(tmp, "wb")); f:write(text); f:close()
        os.rename(tmp, path)
      end
    end
  end
  local h = require("workflow").hash(table.concat(all, "\0"))
  bog.store.kv_set("story.mirror." .. book, h)
  return h
end

-- Replace the book's rows with the mirror's. -> counts
function M.import(book, root)
  M.ensure_schema()
  local dir = mirror_dir(root)
  local counts, all = {}, {}
  M.drop_book(book)
  for _, m in ipairs(M.MIRROR) do
    local text = require("story.book").read(dir .. "/" .. m.file .. ".jsonl") or ""
    all[#all + 1] = text
    local n = 0
    for line in text:gmatch("[^\n]+") do
      local r = json.decode(line)
      r.book = book
      local cs, ms, vs = {}, {}, {}
      for k, v in pairs(r) do
        if v == json.null then v = nil end
        cs[#cs + 1] = k
        if v == nil then ms[#ms + 1] = "NULL" else ms[#ms + 1] = "?"; vs[#vs + 1] = v end
      end
      run("INSERT INTO " .. m.tbl .. "(" .. table.concat(cs, ",") .. ") VALUES(" .. table.concat(ms, ",") .. ")", vs)
      n = n + 1
    end
    counts[m.file] = n
  end
  -- rebuild the search index from the rows
  for _, e in ipairs(q("SELECT * FROM st_entity WHERE book = ?", { book })) do
    local names = {}
    for _, a in ipairs(q("SELECT alias FROM st_alias WHERE book = ? AND entity = ?", { book, e.id })) do names[#names + 1] = a.alias end
    fts_put(book, "entity", e.id, e.name .. "\n" .. table.concat(names, ", ") .. "\n" .. (e.body or ""))
  end
  for _, f in ipairs(q("SELECT id, body FROM st_fact WHERE book = ?", { book })) do fts_put(book, "fact", f.id, f.body) end
  for _, e in ipairs(q("SELECT id, summary FROM st_event WHERE book = ?", { book })) do fts_put(book, "event", e.id, e.summary) end
  for _, p in ipairs(q("SELECT id, body FROM st_promise WHERE book = ?", { book })) do fts_put(book, "promise", p.id, p.body) end
  for _, k in ipairs(q("SELECT id, version FROM st_knows WHERE book = ?", { book })) do fts_put(book, "knows", k.id, k.version) end
  bog.store.kv_set("story.mirror." .. book, require("workflow").hash(table.concat(all, "\0")))
  return counts
end

-- Before any read: if the mirror on disk is not what this store last wrote or
-- read (a git pull, a hand edit, a wiped boggart.db), the mirror wins.
function M.sync_in(book, root)
  M.ensure_schema()
  local dir = mirror_dir(root)
  if sys.stat(dir) ~= "dir" then return false end
  local all = {}
  for _, m in ipairs(M.MIRROR) do all[#all + 1] = require("story.book").read(dir .. "/" .. m.file .. ".jsonl") or "" end
  local h = require("workflow").hash(table.concat(all, "\0"))
  if bog.store.kv_get("story.mirror." .. book) == h then return false end
  M.import(book, root)
  return true
end

return M
