-- story/world.lua -- the `story` tool's nouns over the story model
-- (lua/story/model.lua): entity, event, fact, knows, promise, exemption,
-- proposal, lore, model.
--
-- WHO IS ASKING decides what a write does (docs/story-model.md, decision 3):
--   * the author, typing /story ... or `boggart story ...`  -> canon, directly;
--   * the model, calling the `story` tool                    -> a PROPOSAL, which
--     only the author can accept (/story proposal accept ids=Q3 | group=ch07 | all=true).
-- Reads are the same for both. Every read first syncs the model from the
-- book's committed mirror; every write re-exports it.
local sb = require("story.book")
local sm = require("story.model")
local json = require("json")
local M = {}

local function E(m) return "Error: " .. m end

local function open(a)
  local b, e = sb.resolve(a.book)
  if not b then return nil, e end
  sm.ensure_schema()
  sm.sync_in(b.name, b.root)
  return b
end

local function list_of(s)
  local out = {}
  if type(s) == "table" then return s end
  for raw in tostring(s or ""):gmatch("[^,;]+") do
    local x = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if x ~= "" then out[#out + 1] = x end
  end
  return out
end

-- A write: applied (author) or proposed (model). `summary` is what the author
-- reads in the proposal list.
local function write(b, a, kind, action, payload, summary)
  if a._author then
    local fn = sm.APPLY[kind .. "." .. action]
    local res, err = fn(b.name, payload, "author")
    if not res then return E(tostring(err)) end
    sm.export(b.name, b.root)
    return string.format("%s %s: %s", kind, action == "add" and "added" or action, tostring(res))
  end
  local ev
  if a.evidence_path or a.quote then
    ev = { path = a.evidence_path, line = tonumber(a.evidence_line), quote = a.quote }
  end
  local id, e = sm.propose(b.name, { kind = kind, action = action, payload = payload, summary = summary,
    evidence = ev, origin = a.origin or "model", grp = a.group, plan_match = a.plan_match == true }, b.root)
  if not id then return E(tostring(e)) end
  sm.export(b.name, b.root)
  return string.format("Proposed %s: %s\n(Canon changes only when the author accepts it: /story proposal accept ids=%s)",
    id, summary, id)
end

local function as_of(a) return tonumber(a.as_of or a.t) end

-- ---- entity -----------------------------------------------------------------------------------
local function entity_add(a)
  local b, e = open(a); if not b then return E(e) end
  local p = { kind = a.kind or "character", name = a.name, aliases = list_of(a.aliases), parent = a.parent,
              body = a.body or a.text, discoverability = a.discoverability, distinct = a.distinct == true,
              source = a.source }
  if not p.name then return E("entity add needs name=") end
  -- check resolution up front so the model hears about a clash now, not at accept time
  if not p.distinct then
    for _, nm in ipairs({ p.name, table.unpack(p.aliases) }) do
      for _, r in ipairs(sm.resolve(b.name, nm)) do
        if r.kind == p.kind then
          return E(string.format("'%s' already names %s (%s): use `entity alias` to add a name, or distinct=true", nm, r.id, r.name))
        end
      end
    end
  end
  return write(b, a, "entity", "add", p, p.kind .. " " .. p.name .. (#p.aliases > 0 and (" (aka " .. table.concat(p.aliases, ", ") .. ")") or ""))
end

local function entity_alias(a)
  local b, e = open(a); if not b then return E(e) end
  if not a.alias then return E("entity alias needs name= and alias=") end
  local ent, ee = sm.resolve1(b.name, a.name)
  if not ent then return E(ee) end
  return write(b, a, "entity", "alias", { entity = ent.id, alias = a.alias }, ent.id .. " is also called '" .. a.alias .. "'")
end

local function entity_update(a)
  local b, e = open(a); if not b then return E(e) end
  local ent, ee = sm.resolve1(b.name, a.name or a.id)
  if not ent then return E(ee) end
  local p = { id = ent.id, body = a.body or a.text, parent = a.parent, discoverability = a.discoverability }
  return write(b, a, "entity", "update", p, "update " .. ent.id)
end

local function entity_resolve(a)
  local b, e = open(a); if not b then return E(e) end
  local rs = sm.resolve(b.name, a.name)
  if #rs == 0 then
    local hits = sm.search(b.name, a.name, "entity", "or")
    if #hits == 0 then return "No entity called '" .. tostring(a.name) .. "'." end
    local out = { "No exact name; closest:" }
    for _, h in ipairs(hits) do out[#out + 1] = "  " .. h.id end
    return table.concat(out, "\n")
  end
  local out = {}
  for _, r in ipairs(rs) do out[#out + 1] = string.format("%s  (%s) %s", r.id, r.kind, r.name) end
  return table.concat(out, "\n")
end

local function entity_list(a)
  local b, e = open(a); if not b then return E(e) end
  local sql, p = "SELECT * FROM st_entity WHERE book = ?", { b.name }
  if a.kind then sql = sql .. " AND kind = ?"; p[#p + 1] = a.kind end
  local rows = sm.q(sql .. " ORDER BY kind, id", p) or {}
  if #rows == 0 then return "No entities yet." end
  local out, last = {}, nil
  for _, r in ipairs(rows) do
    if r.kind ~= last then out[#out + 1] = "## " .. r.kind; last = r.kind end
    local al = {}
    for _, x in ipairs(sm.q("SELECT alias FROM st_alias WHERE book = ? AND entity = ? AND alias != ?", { b.name, r.id, r.name }) or {}) do al[#al + 1] = x.alias end
    out[#out + 1] = string.format("  %-22s %s%s%s", r.id, r.name, #al > 0 and (" (aka " .. table.concat(al, ", ") .. ")") or "",
      r.parent and ("  in " .. r.parent) or "")
  end
  return table.concat(out, "\n")
end

-- One entity as of story time t: its sheet, where it is, what it holds, its
-- relations, and what it knows / does not know.
local function entity_get(a)
  local b, e = open(a); if not b then return E(e) end
  local ent, ee = sm.resolve1(b.name, a.name or a.id)
  if not ent then return E(ee) end
  local t = as_of(a)
  local st = sm.state(b.name, ent.id, t)
  local al = {}
  for _, x in ipairs(sm.q("SELECT alias FROM st_alias WHERE book = ? AND entity = ?", { b.name, ent.id }) or {}) do al[#al + 1] = x.alias end
  local out = { string.format("%s — %s (%s)%s", ent.id, ent.name, ent.kind, t and ("   as of t=" .. t) or "   (now)") }
  out[#out + 1] = "aka: " .. table.concat(al, ", ")
  if ent.parent then out[#out + 1] = "within: " .. ent.parent end
  if ent.body and ent.body ~= "" then out[#out + 1] = ent.body end
  if st.ended then out[#out + 1] = "ENDED at t=" .. st.ended end
  if st.place then out[#out + 1] = "at: " .. st.place end
  if #st.items > 0 then out[#out + 1] = "holds: " .. table.concat(st.items, ", ") end
  local fk = {}
  for k, v in pairs(st.fields) do fk[#fk + 1] = k .. "=" .. v end
  table.sort(fk)
  if #fk > 0 then out[#out + 1] = "state: " .. table.concat(fk, ", ") end
  local rel = {}
  for other, r in pairs(st.relations) do
    local fs = {}
    for f, v in pairs(r) do fs[#fs + 1] = f .. " " .. v end
    table.sort(fs)
    rel[#rel + 1] = other .. " (" .. table.concat(fs, ", ") .. ")"
  end
  table.sort(rel)
  if #rel > 0 then out[#out + 1] = "relations: " .. table.concat(rel, "; ") end
  if ent.kind == "item" then
    local h = sm.holder(b.name, ent.id, t)
    out[#out + 1] = "held by: " .. (h or "nobody")
  elseif ent.kind == "place" then
    local here = sm.present(b.name, ent.id, t)
    if #here > 0 then out[#out + 1] = "present: " .. table.concat(here, ", ") end
  end
  local facts = sm.facts_at(b.name, t, { subject = ent.id })
  if #facts > 0 then
    out[#out + 1] = "facts:"
    for _, f in ipairs(facts) do
      out[#out + 1] = string.format("  %s [%s%s] %s", f.id, f.visibility, f.modality ~= "true" and ("/" .. f.modality) or "", f.body)
    end
  end
  if ent.kind == "character" then
    local kn = sm.known(b.name, ent.id, t)
    out[#out + 1] = "knows (" .. #kn .. "):"
    for _, k in ipairs(kn) do
      out[#out + 1] = string.format("  %s since t=%s (%s%s): %s", k.fact, tostring(k.learned_t), k.how,
        k.from_entity and (" by " .. k.from_entity) or "", (k.version ~= "" and k.version) or k.fact_body)
    end
    local un = sm.unknown(b.name, ent.id, t)
    if #un > 0 then
      out[#out + 1] = "does NOT yet know:"
      for _, f in ipairs(un) do out[#out + 1] = "  " .. f.id .. " " .. f.body end
    end
  end
  return table.concat(out, "\n")
end

-- ---- event ----------------------------------------------------------------------------------------
local function event_add(a)
  local b, e = open(a); if not b then return E(e) end
  if not a.t then return E("event add needs t= (story time; pos= if told elsewhere)") end
  local p = { t = tonumber(a.t), pos = tonumber(a.pos), scene = a.scene, kind = a.kind, summary = a.summary or a.text,
              deltas = sm.split_deltas(a.deltas), secret = a.secret == true, source = a.source }
  -- validate deltas now (names resolve, syntax parses) so a bad proposal never queues
  for _, line in ipairs(p.deltas) do
    local d, de = sm.parse_delta(line)
    if not d then return E(de) end
    local _, ee = sm.resolve1(b.name, d.entity)
    if ee then return E(ee) end
    if d.target then local _, te = sm.resolve1(b.name, d.target); if te then return E(te) end end
  end
  if a._author then
    local id, w = sm.add_event(b.name, p, "author")
    if not id then return E(tostring(w)) end
    sm.export(b.name, b.root)
    return "event added: " .. id .. ((#w > 0) and ("\nWARNING: " .. table.concat(w, "\nWARNING: ")) or "")
  end
  return write(b, a, "event", "add", p, string.format("t=%s %s%s", tostring(p.t), p.summary or "",
    #p.deltas > 0 and (" [" .. table.concat(p.deltas, "; ") .. "]") or ""))
end

local function event_list(a)
  local b, e = open(a); if not b then return E(e) end
  local rows = sm.q([[SELECT * FROM st_event WHERE book = ? AND status = 'canon'
    AND t >= ? AND t <= ? ORDER BY t, id]], { b.name, tonumber(a.from) or -1e18, tonumber(a.to) or 1e18 }) or {}
  if #rows == 0 then return "No events." end
  local out = {}
  for _, r in ipairs(rows) do
    local ds = {}
    for _, d in ipairs(sm.q("SELECT * FROM st_delta WHERE book = ? AND event = ? ORDER BY n", { b.name, r.id }) or {}) do
      ds[#ds + 1] = d.op .. " " .. d.entity .. (d.field and (" " .. d.field .. "=" .. tostring(d.value)) or "") .. (d.target and (" -> " .. d.target) or "")
    end
    out[#out + 1] = string.format("t=%-6s pos=%-6s %s %s%s", r.t, r.pos, r.id, r.summary,
      #ds > 0 and ("\n      " .. table.concat(ds, "; ")) or "")
  end
  return table.concat(out, "\n")
end

-- ---- fact -------------------------------------------------------------------------------------------
local function fact_payload(a)
  return { body = a.body or a.text, subject = a.subject, kind = a.kind, visibility = a.visibility,
           modality = a.modality, holder = a.holder, valid_from = a.valid_from, valid_to = a.valid_to,
           withhold_until = a.withhold_until, importance = a.importance, source = a.source, note = a.note,
           status = a.status }
end

local function fact_add(a)
  local b, e = open(a); if not b then return E(e) end
  local p = fact_payload(a)
  if not p.body then return E("fact add needs body=") end
  if p.subject then local _, se = sm.resolve1(b.name, p.subject); if se then return E("subject: " .. se) end end
  return write(b, a, "fact", "add", p, string.format("%s fact%s: %s", p.visibility or "public",
    p.subject and (" about " .. p.subject) or "", p.body))
end

local function fact_retcon(a)
  local b, e = open(a); if not b then return E(e) end
  local old = sm.fact(b.name, tostring(a.id or ""):upper())
  if not old then return E("no fact " .. tostring(a.id)) end
  local p = fact_payload(a)
  p.id = old.id
  return write(b, a, "fact", "retcon", p, "retcon " .. old.id .. ": \"" .. old.body .. "\" -> \"" .. tostring(p.body or old.body) .. "\"")
end

local function fact_list(a)
  local b, e = open(a); if not b then return E(e) end
  local rows
  if a.status and a.status ~= "canon" then
    rows = sm.q("SELECT * FROM st_fact WHERE book = ? AND status = ? ORDER BY id", { b.name, a.status }) or {}
  else
    local subj
    if a.subject then local s, se = sm.resolve1(b.name, a.subject); if not s then return E(se) end; subj = s.id end
    rows = sm.facts_at(b.name, as_of(a), { subject = subj, pos = tonumber(a.pos) })
  end
  if #rows == 0 then return "No facts." end
  local out = {}
  for _, f in ipairs(rows) do
    out[#out + 1] = string.format("%s [%s/%s%s%s]%s %s", f.id, f.status, f.visibility,
      f.modality ~= "true" and ("/" .. f.modality .. (f.holder and (" by " .. f.holder) or "")) or "",
      f.withhold_until and ("/withheld until pos " .. f.withhold_until) or "",
      f.subject and (" (" .. f.subject .. ")") or "", f.body)
  end
  return table.concat(out, "\n")
end

local function fact_get(a)
  local b, e = open(a); if not b then return E(e) end
  local f = sm.fact(b.name, tostring(a.id or ""):upper())
  if not f then return E("no fact " .. tostring(a.id)) end
  local out = { string.format("%s — %s", f.id, f.body),
    string.format("status %s, %s, modality %s%s, kind %s, importance %s", f.status, f.visibility, f.modality,
      f.holder and (" (" .. f.holder .. ")") or "", f.kind, tostring(f.importance)),
    "source: " .. tostring(f.source) }
  if f.subject then out[#out + 1] = "about: " .. f.subject end
  if f.valid_from or f.valid_to then out[#out + 1] = string.format("true from t=%s to t=%s", tostring(f.valid_from or "start"), tostring(f.valid_to or "end")) end
  if f.withhold_until then out[#out + 1] = "withheld from drafting until pos " .. f.withhold_until end
  if f.superseded_by then out[#out + 1] = "superseded by " .. f.superseded_by end
  local who = sm.who_knows(b.name, f.id)
  if #who > 0 then
    out[#out + 1] = "known by:"
    for _, k in ipairs(who) do
      out[#out + 1] = string.format("  %s since %s (%s%s)", k.holder,
        k.holder == sm.READER and ("pos " .. tostring(k.learned_pos)) or ("t=" .. tostring(k.learned_t)), k.how,
        k.from_entity and (" by " .. k.from_entity) or "")
    end
  else
    out[#out + 1] = "known by: nobody yet"
  end
  return table.concat(out, "\n")
end

-- ---- knows -------------------------------------------------------------------------------------------
local function knows_add(a)
  local b, e = open(a); if not b then return E(e) end
  local holder = a.holder or a.name
  if not holder then return E("knows add needs holder= (a character, or reader)") end
  if holder ~= sm.READER then local _, he = sm.resolve1(b.name, holder); if he then return E("holder: " .. he) end end
  local f = sm.fact(b.name, tostring(a.fact or ""):upper())
  if not f then return E("no fact " .. tostring(a.fact)) end
  local p = { holder = holder, fact = f.id, t = a.t, pos = a.pos, how = a.how, from = a.from, version = a.version,
              confidence = a.confidence, source = a.source }
  return write(b, a, "knows", "add", p, string.format("%s learns %s (%s) at %s", holder, f.id, f.body,
    holder == sm.READER and ("pos " .. tostring(a.pos)) or ("t=" .. tostring(a.t))))
end

local function knows_what(a)
  local b, e = open(a); if not b then return E(e) end
  local holder = a.holder or a.name
  if holder ~= sm.READER then
    local ent, ee = sm.resolve1(b.name, holder)
    if not ent then return E(ee) end
    holder = ent.id
  end
  local at = holder == sm.READER and tonumber(a.pos or a.as_of) or as_of(a)
  local out = { holder .. " knows" .. (at and (" as of " .. (holder == sm.READER and "pos " or "t=") .. at) or "") .. ":" }
  for _, k in ipairs(sm.known(b.name, holder, at)) do
    out[#out + 1] = string.format("  %s %s%s", k.fact, (k.version ~= "" and k.version) or k.fact_body,
      k.version ~= "" and ("  (true: " .. k.fact_body .. ")") or "")
  end
  if #out == 1 then out[#out + 1] = "  nothing recorded" end
  local un = sm.unknown(b.name, holder, at)
  if #un > 0 then
    out[#out + 1] = "does NOT yet know:"
    for _, f in ipairs(un) do out[#out + 1] = "  " .. f.id .. " " .. f.body end
  end
  return table.concat(out, "\n")
end

local function knows_who(a)
  a.id = a.fact or a.id
  return fact_get(a)
end

-- ---- promise, exemption -----------------------------------------------------------------------------
local function promise_add(a)
  local b, e = open(a); if not b then return E(e) end
  local p = { kind = a.kind or "promise", body = a.body or a.text, setup = a.setup, thread = a.thread,
              due_pos = a.due_pos, source = a.source }
  if not p.body then return E("promise add needs body=") end
  return write(b, a, "promise", "add", p, p.kind .. ": " .. p.body)
end

local function promise_pay(a)
  local b, e = open(a); if not b then return E(e) end
  local id = tostring(a.id or ""):upper()
  local r = (sm.q("SELECT * FROM st_promise WHERE book = ? AND id = ?", { b.name, id }) or {})[1]
  if not r then return E("no promise " .. id) end
  return write(b, a, "promise", "pay", { id = id, payoff = a.payoff or "" }, "pay " .. id .. " (" .. r.body .. ") with " .. tostring(a.payoff))
end

local function promise_list(a)
  local b, e = open(a); if not b then return E(e) end
  local rows = sm.q("SELECT * FROM st_promise WHERE book = ? AND status = ? ORDER BY CAST(SUBSTR(id,2) AS INTEGER)",
    { b.name, a.status or "open" }) or {}
  if #rows == 0 then return "No " .. (a.status or "open") .. " promises." end
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = string.format("%s [%s] %s%s%s", r.id, r.kind, r.body, r.due_pos and ("  due by pos " .. r.due_pos) or "",
      r.payoff and ("  paid by " .. r.payoff) or "")
  end
  return table.concat(out, "\n")
end

local function exemption_add(a)
  local b, e = open(a); if not b then return E(e) end
  return write(b, a, "exemption", "add", { kind = a.kind, target = a.target, reason = a.reason or a.text },
    "exempt " .. tostring(a.target) .. ": " .. tostring(a.reason or a.text))
end

local function exemption_list(a)
  local b, e = open(a); if not b then return E(e) end
  local rows = sm.q("SELECT * FROM st_exemption WHERE book = ? ORDER BY id", { b.name }) or {}
  if #rows == 0 then return "No exemptions." end
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = string.format("%s [%s] %s: %s", r.id, r.kind, r.target, r.reason) end
  return table.concat(out, "\n")
end

-- ---- proposals --------------------------------------------------------------------------------------
local function proposal_list(a)
  local b, e = open(a); if not b then return E(e) end
  local sql, p = "SELECT * FROM st_proposal WHERE book = ? AND status = ?", { b.name, a.status or "pending" }
  if a.group then sql = sql .. " AND grp = ?"; p[#p + 1] = a.group end
  local rows = sm.q(sql .. " ORDER BY grp, kind, CAST(SUBSTR(id,2) AS INTEGER)", p) or {}
  if #rows == 0 then return "No " .. (a.status or "pending") .. " proposals." end
  local out, last = {}, nil
  for _, r in ipairs(rows) do
    local g = (r.grp ~= "" and r.grp or "(ungrouped)") .. " / " .. r.kind
    if g ~= last then out[#out + 1] = "## " .. g; last = g end
    local ev = r.evidence ~= "" and json.decode(r.evidence) or nil
    out[#out + 1] = string.format("  %s%s %s", r.id, r.plan_match == 1 and " (in plan)" or "", r.summary)
    if ev then
      out[#out + 1] = string.format("      evidence %s%s: \"%s\"", tostring(ev.path or ""), ev.line and (":" .. ev.line) or "",
        tostring(ev.quote or ""):sub(1, 140))
    end
    if r.result ~= "" then out[#out + 1] = "      " .. r.result end
  end
  out[#out + 1] = "Accept: /story proposal accept ids=Q1,Q2 | group=<g> | all=true   Reject: /story proposal reject ..."
  return table.concat(out, "\n")
end

local function proposal_decide(a, accept)
  if not a._author then
    return E("only the author accepts or rejects proposals (they are shown with /story proposal list)")
  end
  local b, e = open(a); if not b then return E(e) end
  local rows = sm.select_proposals(b.name, { ids = a.ids or a.id, group = a.group, all = a.all == true })
  if #rows == 0 then return E("no matching proposals (ids=, group= or all=true)") end
  local res = accept and sm.accept(b.name, rows) or sm.reject(b.name, rows, a.reason)
  sm.export(b.name, b.root)
  return table.concat(res, "\n")
end

-- ---- lore search, model ---------------------------------------------------------------------------------
local function lore_search(a)
  local b, e = open(a); if not b then return E(e) end
  local hits = sm.search(b.name, a.query or a.text, a.kind, a.mode)
  if #hits == 0 then return "No lore matches '" .. tostring(a.query or a.text) .. "'." end
  local out = {}
  for _, h in ipairs(hits) do
    local t = h.text:gsub("\n", " / ")
    if #t > 160 then t = t:sub(1, 157) .. "..." end
    out[#out + 1] = string.format("%-8s %-10s %s", h.kind, h.id, t)
  end
  return table.concat(out, "\n")
end

local function model_status(a)
  local b, e = open(a); if not b then return E(e) end
  local function n(t, w) return ((sm.q("SELECT count(*) AS n FROM " .. t .. " WHERE book = ?" .. (w or ""), { b.name }) or {})[1] or {}).n or 0 end
  return string.format("%s: %d entities, %d events, %d canon facts (%d retconned), %d knowledge rows, "
    .. "%d open promises, %d pending proposals\nmirror: %s/.boggart/story/", b.name, n("st_entity"), n("st_event"),
    n("st_fact", " AND status = 'canon'"), n("st_fact", " AND status = 'retconned'"), n("st_knows"),
    n("st_promise", " AND status = 'open'"), n("st_proposal", " AND status = 'pending'"), b.root)
end

local function model_export(a)
  local b, e = open(a); if not b then return E(e) end
  local h = sm.export(b.name, b.root)
  return "Exported to " .. b.root .. "/.boggart/story/ (" .. h:sub(1, 12) .. ")"
end

local function model_import(a)
  if not a._author then return E("only the author re-imports the mirror (it replaces the model)") end
  local b, e = sb.resolve(a.book); if not b then return E(e) end
  local c = sm.import(b.name, b.root)
  local parts = {}
  for k, v in pairs(c) do parts[#parts + 1] = k .. " " .. v end
  table.sort(parts)
  return "Imported: " .. table.concat(parts, ", ")
end

M.ACTIONS = {
  entity = { add = entity_add, alias = entity_alias, update = entity_update, resolve = entity_resolve,
             list = entity_list, get = entity_get },
  event = { add = event_add, list = event_list },
  fact = { add = fact_add, retcon = fact_retcon, list = fact_list, get = fact_get },
  knows = { add = knows_add, what = knows_what, who = knows_who },
  promise = { add = promise_add, pay = promise_pay, list = promise_list },
  exemption = { add = exemption_add, list = exemption_list },
  proposal = { list = proposal_list, accept = function(a) return proposal_decide(a, true) end,
               reject = function(a) return proposal_decide(a, false) end },
  lore = { search = lore_search },
  model = { status = model_status, export = model_export, import = model_import },
}
M.DEFAULT = { lore = "search", model = "status", proposal = "list" }

M.DESCRIPTION = "THE STORY MODEL (what is true, when, and who knows it; writes by the model become PROPOSALS the "
  .. "author accepts): entity add (kind=character|place|item|faction, name=, aliases=, parent=, body=)|alias|update|"
  .. "resolve|list|get (name=, as_of=t: state, holdings, relations, knows / does NOT know); "
  .. "event add (t= story time, pos= narrative position if told elsewhere, summary=, deltas=\"move X to Y; X acquires Y; "
  .. "X loses Y; X field=value; relate X Y trust +2; end X\")|list; "
  .. "fact add (body=, subject=, visibility=public|secret, modality=true|claimed|rumour|belief|joke, holder=, "
  .. "valid_from=, valid_to=, withhold_until=pos)|retcon (id=, body=)|list|get; "
  .. "knows add (holder=character|reader, fact=, t= or pos=, how=witnessed|told|read|inferred|rumour, from=, version=)|"
  .. "what (holder=, as_of=)|who (fact=); promise add (kind=promise|question|clue|chekhov, body=, due_pos=)|pay|list; "
  .. "exemption add|list; proposal list; lore search (query=); model status|export. "
  .. "Give evidence for anything read from the text: evidence_path=, evidence_line=, quote= (must appear verbatim)."

M.PROPS = {
  aliases = { type = "string", description = "comma-separated other names" },
  parent = { type = "string" }, body = { type = "string" }, discoverability = { type = "string" },
  distinct = { type = "boolean" }, alias = { type = "string" },
  t = { type = "number", description = "story time (when it happens)" },
  pos = { type = "number", description = "narrative position (where the book tells it)" },
  as_of = { type = "number" }, scene = { type = "string" }, summary = { type = "string" },
  deltas = { type = "string" }, secret = { type = "boolean" },
  subject = { type = "string" }, visibility = { type = "string" }, modality = { type = "string" },
  holder = { type = "string" }, valid_from = { type = "number" }, valid_to = { type = "number" },
  withhold_until = { type = "number" }, importance = { type = "integer" }, note = { type = "string" },
  fact = { type = "string" }, how = { type = "string" }, from = { type = "string" }, version = { type = "string" },
  confidence = { type = "number" }, setup = { type = "string" }, thread = { type = "string" },
  due_pos = { type = "number" }, payoff = { type = "string" }, reason = { type = "string" },
  ids = { type = "string" }, group = { type = "string" }, all = { type = "boolean" },
  status = { type = "string" }, mode = { type = "string" },
  evidence_path = { type = "string" }, evidence_line = { type = "integer" },
  quote = { type = "string", description = "verbatim text from evidence_path supporting the proposal" },
  plan_match = { type = "boolean" }, source = { type = "string" }, origin = { type = "string" },
}

return M
