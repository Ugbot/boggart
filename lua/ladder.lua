-- ladder.lua -- the tier ladder: code -> jev (+ code) -> llm, per decision site.
--
-- Every place the runtime asks "what next?" can be answered by a stack of
-- stages, cheapest first. A stage returns a verdict and how sure it is, or
-- nothing (abstain); the first stage that is sure enough wins, and anything
-- below it falls through to the next:
--
--   code   pure Lua: a rule, a predicate, a verify command. Certain or silent.
--   local  retrieval with no model (skillrouter / learning.route). Scored.
--   jev    a typed question put to System One (lua/judge.lua jev_only).
--   llm    the existing chat path. Always last, always accepted.
--
--   ladder.define{ id = "swarm.supervise", stages = {
--     ladder.code(function(ctx) if ctx.exited then return "done" end end),
--     ladder.jev{ state = function(ctx) return ctx.tail end,
--                 questions = { s = { kind = "choice", instructions = "...", options = {...} } },
--                 map = function(a) return a.s.choice end },
--     ladder.llm(function(ctx) return ask_the_model(ctx) end),
--   } }
--   local verdict, meta = ladder.run("swarm.supervise", ctx)
--
-- OPTIONAL BY CONSTRUCTION. A site is off until switched on (`/ladder on <id>`);
-- an off site runs only its llm stage, which is exactly what the caller did
-- before the ladder existed. `/judge off|chat` and a missing key drop the jev
-- stage the same way. Jev errors never surface -- they fall through -- and
-- the reason is kept in meta.tried.
--
-- MEASURING. A routed verdict (anything the llm stage did not give) is, with
-- probability `sample`, ALSO put to the llm stage; the two are compared and the
-- agreement is recorded (telemetry kind "ladder"). The caller still gets the
-- routed verdict: the sample is the thermometer, not the decision.
--
-- HARDENING (lua/harden.lua is the command surface). A site that supplies
-- `key = fn(ctx)` -> string can have repeated decisions folded into a code-tier
-- memo: a verdict that a lower tier gave and the llm sample AGREED with, `min_obs`
-- times in a row for the same key, is answered by pure code thereafter. The memo
-- is rechecked against the ladder below it at `recheck`; one disagreement drops
-- that entry, `max_bad` of them disable hardening for the site (rollback). The
-- code tier answering this way reports meta.memo = true.
--
-- Settings (kv, shared by TUI and studio):
--   config.ladder.master            on|off   (default on)
--   config.ladder.<id>.enabled      on|off   (default: the site's `default`, else off)
--   config.ladder.<id>.threshold    0..1     (default 0.85)
--   config.ladder.<id>.sample       0..1     (default 0.05)
--   config.harden.master            on|off   (default on)
--   config.ladder.<id>.harden       on|off   (default on for sites that define `key`)
--   ladder.memo.<id>                the memo (JSON)
local M = {}

M.DEFAULTS = { threshold = 0.85, sample = 0.05 }
M.TIERS = { code = 1, ["local"] = 2, jev = 3, llm = 4 }

local sites, order = {}, {}

M.rand = math.random -- overridable for tests
M.HARDEN = { min_obs = 3, recheck = 0.05, max_bad = 3, max_entries = 500 }

-- ---- config ----------------------------------------------------------------
local function kv_get(k)
  local st = type(bog) == "table" and bog.store
  if not (st and st.kv_get) then return nil end
  local ok, v = pcall(st.kv_get, k)
  return ok and v or nil
end
local function kv_set(k, v)
  local st = type(bog) == "table" and bog.store
  if st and st.kv_set then pcall(st.kv_set, k, v) end
end

local function onoff(v, default)
  if v == nil then return default end
  v = tostring(v)
  if v == "on" or v == "1" or v == "true" then return true end
  if v == "off" or v == "0" or v == "false" then return false end
  return default
end

local function unit(v, default)
  local n = tonumber(v)
  if n and n >= 0 and n <= 1 then return n end
  return default
end

function M.master() return onoff(kv_get("config.ladder.master"), true) end

function M.set_master(on)
  kv_set("config.ladder.master", on and "on" or "off")
  return on
end

local function key(id, field) return "config.ladder." .. id .. "." .. field end

function M.enabled(id)
  local s = sites[id]
  if not s or not M.master() then return false end
  return onoff(kv_get(key(id, "enabled")), s.default == true)
end

function M.set_enabled(id, on)
  if not sites[id] then return nil, "unknown site: " .. tostring(id) end
  kv_set(key(id, "enabled"), on and "on" or "off")
  return on
end

function M.threshold(id)
  local s = sites[id]
  return unit(kv_get(key(id, "threshold")), s and s.threshold or M.DEFAULTS.threshold)
end

function M.sample(id)
  local s = sites[id]
  return unit(kv_get(key(id, "sample")), s and s.sample or M.DEFAULTS.sample)
end

function M.set_number(id, field, v)
  if not sites[id] then return nil, "unknown site: " .. tostring(id) end
  if field ~= "threshold" and field ~= "sample" then return nil, "unknown setting: " .. tostring(field) end
  local n = tonumber(v)
  if not n or n < 0 or n > 1 then return nil, field .. " must be a number in 0..1" end
  kv_set(key(id, field), tostring(n))
  return n
end

-- ---- the memo (hardening) ----------------------------------------------------
local memos = {} -- id -> { cases = { key -> {v=<json>, n=<agreements>} }, bad = n }

local function json_ok() local ok, j = pcall(require, "json"); return ok and j or nil end

local function memo_of(id)
  local m = memos[id]
  if m then return m end
  m = { cases = {}, bad = 0 }
  local j = json_ok()
  local raw = kv_get("ladder.memo." .. id)
  if j and type(raw) == "string" and raw ~= "" then
    local ok, d = pcall(j.decode, raw)
    if ok and type(d) == "table" and type(d.cases) == "table" then m = { cases = d.cases, bad = tonumber(d.bad) or 0 } end
  end
  memos[id] = m
  return m
end

local function memo_save(id)
  local j = json_ok()
  if j then
    local ok, s = pcall(j.encode, memos[id])
    if ok then kv_set("ladder.memo." .. id, s) end
  end
end

local function enc(v)
  local j = json_ok()
  if not j then return nil end
  local ok, s = pcall(j.encode, { v = v })
  return ok and s or nil
end

function M.harden_master() return onoff(kv_get("config.harden.master"), true) end
function M.set_harden_master(on) kv_set("config.harden.master", on and "on" or "off"); return on end

function M.harden_enabled(id)
  local s = sites[id]
  if not (s and s.key and M.master() and M.harden_master()) then return false end
  return onoff(kv_get(key(id, "harden")), true)
end

function M.set_harden(id, on)
  if not sites[id] then return nil, "unknown site: " .. tostring(id) end
  if not sites[id].key then return nil, id .. " has no stable key to harden on" end
  kv_set(key(id, "harden"), on and "on" or "off")
  return on
end

-- The promoted verdict for `k`, decoded, or nil.
local function memo_get(id, k)
  local c = memo_of(id).cases[k]
  if not (c and (c.n or 0) >= M.HARDEN.min_obs) then return nil end
  local j = json_ok()
  local ok, d = pcall(j.decode, c.v)
  if ok and type(d) == "table" then return d.v, true end
  return nil
end

-- One verified (good) or refuted (not good) observation of `verdict` for key `k`.
function M.observe(id, k, verdict, good)
  local m, e = memo_of(id), enc(verdict)
  if not (e and k) then return end
  local c = m.cases[k]
  if not good then
    if c then m.cases[k] = nil; memo_save(id) end
    return
  end
  if not c then
    local n = 0
    for _ in pairs(m.cases) do n = n + 1 end
    if n >= M.HARDEN.max_entries then return end
    c = { v = e, n = 0 }
    m.cases[k] = c
  end
  if c.v ~= e then c.v, c.n = e, 0 end -- a different verdict restarts the count
  c.n = c.n + 1
  memo_save(id)
end

-- A rechecked entry disagreed: drop it, and after max_bad of them turn the
-- site's hardening off and forget the lot (the rollback).
local function memo_demote(id, k)
  local m = memo_of(id)
  m.cases[k] = nil
  m.bad = m.bad + 1
  if m.bad >= M.HARDEN.max_bad then
    m.cases, m.bad = {}, 0
    kv_set(key(id, "harden"), "off")
  end
  memo_save(id)
end

-- ladder.confirm(meta, good): a caller with ground truth (a verify passed, the
-- user accepted) says whether the verdict in `meta` was right.
function M.confirm(meta, good)
  if type(meta) ~= "table" or not meta.site or meta.key == nil then return false end
  M.observe(meta.site, meta.key, meta.verdict, good == true)
  return true
end

function M.memo_stats(id)
  local m = memo_of(id)
  local entries, promoted = 0, 0
  for _, c in pairs(m.cases) do
    entries = entries + 1
    if (c.n or 0) >= M.HARDEN.min_obs then promoted = promoted + 1 end
  end
  return { entries = entries, promoted = promoted, bad = m.bad }
end

function M.memo_clear(id)
  memos[id] = { cases = {}, bad = 0 }
  memo_save(id)
end

-- ---- stages ----------------------------------------------------------------
-- A stage is { tier, name, run = fn(ctx) -> verdict, confidence?, info? }.
-- verdict == nil abstains. confidence nil means "certain" (code, llm).

function M.code(fn, name) return { tier = "code", name = name or "code", run = fn } end
function M.localstage(fn, name) return { tier = "local", name = name or "local", run = fn } end
function M.llm(fn, name) return { tier = "llm", name = name or "llm", run = fn } end

-- ladder.jev{ state = fn(ctx)|string, questions = table|fn(ctx), map = fn(answers, ctx) -> verdict,
--             model?, timeout?, name? }
-- Confidence is the lowest one jev reported (judge.min_reported_confidence).
-- `map(answers, ctx)` may return nil to abstain, or `verdict, confidence` to override.
function M.jev(spec)
  assert(type(spec) == "table" and type(spec.map) == "function", "ladder.jev needs map=")
  return {
    tier = "jev", name = spec.name or "jev",
    run = function(ctx)
      local judge = (bog and bog.judge) or require("judge")
      local state = type(spec.state) == "function" and spec.state(ctx) or spec.state
      local questions = type(spec.questions) == "function" and spec.questions(ctx) or spec.questions
      if state == nil then return nil, nil, { skipped = "no state" } end
      local answers, meta = judge.jev_only{
        state = state, questions = questions, model = spec.model, timeout = spec.timeout,
      }
      if not answers then
        return nil, nil, { error = meta and (meta.message or meta.kind) or "jev failed",
                           kind = meta and meta.kind }
      end
      -- map may return its own confidence (a set-valued verdict is as sure as the
      -- probability mass it kept, not the top option's confidence)
      local verdict, conf = spec.map(answers, ctx)
      return verdict, conf or meta.confidence, { answers = answers, meta = meta }
    end,
  }
end

-- ---- sites -----------------------------------------------------------------
-- ladder.define{ id, stages, default?, threshold?, sample?, equal?, key? }
-- key(ctx) -> string | nil: a stable identity for "the same decision again";
-- present means the site can be hardened into the code-tier memo.
function M.define(spec)
  assert(type(spec) == "table" and type(spec.id) == "string", "ladder.define needs an id")
  assert(type(spec.stages) == "table" and #spec.stages > 0, "ladder.define needs stages")
  local last = 0
  for _, st in ipairs(spec.stages) do
    local rank = M.TIERS[st.tier]
    assert(rank, "unknown tier: " .. tostring(st.tier))
    assert(rank >= last, "stages must run cheapest first (code, local, jev, llm)")
    last = rank
  end
  if not sites[spec.id] then order[#order + 1] = spec.id end
  sites[spec.id] = spec
  return spec
end

function M.site(id) return sites[id] end
function M.sites() return order end
function M.reset() sites, order, memos = {}, {}, {} end

local function same(site, a, b)
  if site.equal then return site.equal(a, b) end
  return a == b
end

local function llm_stage(site)
  for _, st in ipairs(site.stages) do if st.tier == "llm" then return st end end
end

local function jev_off()
  local judge = bog and bog.judge
  if not judge or not judge.backend then return false end
  local b = judge.backend()
  return b == "off" or b == "chat"
end

local function now_ms()
  local ok, t = pcall(function() return require("telemetry").now_ms() end)
  return ok and t or os.time() * 1000
end

local function record(site, ctx, meta)
  local ok, tel = pcall(require, "telemetry")
  if not ok then return end
  pcall(tel.ladder, ctx and ctx.telemetry or ctx, {
    site = site.id, tier = meta.tier, escalated = meta.escalated, confidence = meta.confidence,
    ms = meta.ms, tried = #meta.tried, agree = meta.agree, memo = meta.memo, rolled_back = meta.rolled_back,
  })
end

-- ladder.run(id, ctx) -> verdict, meta | nil, meta
-- meta = { site, tier, escalated, confidence, ms, tried = { {tier,name,outcome,...} }, enabled, agree? }
-- Never raises: a stage that throws is recorded and treated as an abstain.
function M.run(id, ctx, opts)
  local site = sites[id]
  if not site then return nil, { site = id, tier = "none", tried = {}, error = "unknown site" } end
  local t0 = now_ms()
  local meta = { site = id, tried = {}, enabled = M.enabled(id) }
  local threshold = M.threshold(id)

  local function try(st)
    local ok, verdict, conf, info = pcall(st.run, ctx)
    local row = { tier = st.tier, name = st.name }
    meta.tried[#meta.tried + 1] = row
    if not ok then
      row.outcome, row.error = "error", tostring(verdict)
      return nil
    end
    if type(info) == "table" then row.info = info.error or info.skipped end
    if verdict == nil then row.outcome = "abstain"; return nil end
    row.confidence = conf
    return verdict, conf
  end

  -- Off: the caller's old behaviour, the llm stage alone.
  if not meta.enabled then
    local llm = llm_stage(site)
    if not llm then
      meta.tier, meta.ms = "none", now_ms() - t0
      return nil, meta
    end
    local v, c = try(llm)
    meta.tier, meta.confidence, meta.ms = "llm", c, now_ms() - t0
    return v, meta
  end

  -- hardened: a promoted verdict answers as code, rechecked now and then
  local k
  if site.key and M.harden_enabled(id) then
    local okk, kk = pcall(site.key, ctx)
    if okk and type(kk) == "string" and kk ~= "" then k = kk end
  end
  if k and not (opts and opts.nomemo) then
    local hit = memo_get(id, k)
    if hit ~= nil then
      if M.rand() < M.HARDEN.recheck then
        local fv, fm = M.run(id, ctx, { nomemo = true })
        if fv ~= nil and not same(site, fv, hit) then
          memo_demote(id, k)
          fm.rolled_back = true
          record(site, ctx, fm)
          return fv, fm
        end
      end
      meta.tier, meta.confidence, meta.memo, meta.key, meta.verdict = "code", 1, true, k, hit
      meta.tried[1] = { tier = "code", name = "memo", outcome = "hit" }
      meta.ms = now_ms() - t0
      record(site, ctx, meta)
      return hit, meta
    end
  end

  for _, st in ipairs(site.stages) do
    if not (st.tier == "jev" and jev_off()) then
      local v, c = try(st)
      if v ~= nil then
        local routed = st.tier == "code" or st.tier == "local" or st.tier == "jev"
        if st.tier == "llm" or c == nil or c >= threshold then
          meta.tier, meta.confidence = st.tier, c
          meta.escalated = #meta.tried > 1 and st.tier == "llm"
          if routed then
            -- the thermometer: also ask the llm, compare, keep the routed verdict
            local llm = llm_stage(site)
            local p = M.sample(id)
            if llm and p > 0 and M.rand() < p then
              local lv = try(llm)
              if lv ~= nil then
                meta.agree = same(site, v, lv)
                if k and st.tier ~= "code" then M.observe(id, k, v, meta.agree) end
              end
            end
          end
          if k and st.tier ~= "code" then meta.key, meta.verdict = k, v end
          meta.ms = now_ms() - t0
          record(site, ctx, meta)
          return v, meta
        end
        meta.tried[#meta.tried].outcome = "below threshold"
      end
    end
  end

  meta.tier, meta.escalated, meta.ms = "none", true, now_ms() - t0
  record(site, ctx, meta)
  return nil, meta
end

-- ---- status ----------------------------------------------------------------
function M.status()
  local rows = {}
  for _, id in ipairs(order) do
    local s = sites[id]
    local tiers = {}
    for _, st in ipairs(s.stages) do tiers[#tiers + 1] = st.tier end
    rows[#rows + 1] = {
      id = id, enabled = M.enabled(id), threshold = M.threshold(id), sample = M.sample(id),
      stages = tiers, help = s.help,
    }
  end
  return { master = M.master(), sites = rows }
end

function M.describe()
  local s = M.status()
  local out = { "ladder: master=" .. (s.master and "on" or "off") }
  if #s.sites == 0 then out[#out + 1] = "  (no sites defined)" end
  for _, r in ipairs(s.sites) do
    out[#out + 1] = string.format("  %-22s %-3s  %-18s  threshold=%.2f sample=%.2f%s",
      r.id, r.enabled and "on" or "off", table.concat(r.stages, ">"), r.threshold, r.sample,
      r.help and ("  " .. r.help) or "")
  end
  return table.concat(out, "\n")
end

-- /ladder                      show sites
-- /ladder on|off               master switch
-- /ladder on|off <id>          one site
-- /ladder threshold|sample <id> <0..1>
function M.command(rest)
  rest = rest or ""
  local a, b, c = rest:match("^(%S*)%s*(%S*)%s*(%S*)")
  if a == "" then return M.describe() end
  if a == "on" or a == "off" then
    if b == "" then M.set_master(a == "on"); return M.describe() end
    local ok, e = M.set_enabled(b, a == "on")
    return ok ~= nil and M.describe() or ("ladder: " .. e)
  elseif a == "threshold" or a == "sample" then
    local v, e = M.set_number(b, a, c)
    return v and M.describe() or ("ladder: " .. e)
  end
  return "usage: /ladder [on|off [<site>]] | /ladder threshold|sample <site> <0..1>"
end

return M
