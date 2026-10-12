-- harden.lua -- folding proven decisions into the code tier (lua/harden.lua +
-- lua/ladder.lua HARDENING), and the workflow tier tags. Headless: jev is stubbed.
for _, t in ipairs{ "trk_projects", "trk_tasks", "trk_criteria", "trk_deps", "trk_tags", "trk_tag_rules", "trk_commits", "trk_issues" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local ladder = bog.ladder or require("ladder")
local harden = require("harden")
local workflow = require("workflow")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local kv = {}
bog.store.kv_get = function(k) return kv[k] end
bog.store.kv_set = function(k, v) kv[k] = v end

local jev_calls, jev_choice = 0, "a"
bog.typesafe = bog.typesafe or {}
bog.typesafe.available = function() return true end
bog.typesafe.ask = function()
  jev_calls = jev_calls + 1
  return { q = { type = "choice", choice = jev_choice, confidence = 0.95, probabilities = { [jev_choice] = 0.95 } } }, { status = 200 }
end

local llm_calls, llm_value = 0, "a"
local function define()
  ladder.define{ id = "h.site", sample = 1, key = function(ctx) return ctx.k end, stages = {
    ladder.jev{ state = function(ctx) return ctx.k end,
      questions = { q = { kind = "choice", instructions = "x", options = { a = "A", b = "B" } } },
      map = function(a) return a.q.choice end },
    ladder.llm(function() llm_calls = llm_calls + 1; return llm_value end),
  } }
  ladder.set_enabled("h.site", true)
end
local function reset()
  kv = {}; jev_calls, llm_calls, jev_choice, llm_value = 0, 0, "a", "a"
  ladder.reset(); define()
  ladder.rand = function() return 0 end -- always sample / always recheck
end

-- three agreeing observations promote the key to code
reset()
for i = 1, 3 do
  local v, m = ladder.run("h.site", { k = "same" })
  eq(m.tier, "jev", "observation " .. i .. " is answered by jev")
  eq(m.agree, true, "observation " .. i .. " agrees with the llm sample")
end
do
  local st = ladder.memo_stats("h.site")
  eq(st.promoted, 1, "one key promoted after min_obs agreements")
  jev_calls, llm_calls = 0, 0
  ladder.rand = function() return 1 end -- no recheck
  local v, m = ladder.run("h.site", { k = "same" })
  eq(v, "a", "promoted verdict returned")
  eq(m.tier, "code", "answered by the code tier")
  ok(m.memo, "meta says memo")
  eq(jev_calls + llm_calls, 0, "no jev and no llm traffic on a hit")
  local v2, m2 = ladder.run("h.site", { k = "other" })
  ok(m2.tier ~= "code", "an unseen key is not answered by the memo")
end

-- a different key is independent; fewer than min_obs does not promote
reset()
ladder.run("h.site", { k = "once" }); ladder.run("h.site", { k = "once" })
eq(ladder.memo_stats("h.site").promoted, 0, "two observations are not enough")

-- a disagreement restarts the count
reset()
ladder.run("h.site", { k = "k" }); ladder.run("h.site", { k = "k" })
llm_value = "b"
ladder.run("h.site", { k = "k" })
eq(ladder.memo_stats("h.site").entries, 0, "a disagreeing sample drops the case")

-- recheck disagreement rolls back one entry, repeated ones switch hardening off
reset()
for i = 1, 3 do ladder.run("h.site", { k = "k" }) end
eq(ladder.memo_stats("h.site").promoted, 1, "promoted")
llm_value, jev_choice = "b", "b"
do
  ladder.rand = function() return 0 end -- recheck
  local v, m = ladder.run("h.site", { k = "k" })
  eq(v, "b", "recheck returns the fresh verdict")
  ok(m.rolled_back, "rollback flagged")
  eq(ladder.memo_stats("h.site").promoted, 0, "the entry is gone")
  eq(ladder.memo_stats("h.site").bad, 1, "rollback counted")
end
reset()
for round = 1, 3 do
  llm_value, jev_choice = "a", "a"
  local key = "k" .. round
  for i = 1, 3 do ladder.run("h.site", { k = key }) end
  llm_value, jev_choice = "b", "b"
  ladder.run("h.site", { k = key })
end
eq(ladder.harden_enabled("h.site"), false, "max_bad rollbacks switch hardening off for the site")
eq(ladder.memo_stats("h.site").entries, 0, "and forget the memo")

-- switches
reset()
eq(ladder.harden_enabled("h.site"), true, "on by default for a keyed site")
ladder.set_harden_master(false)
eq(ladder.harden_enabled("h.site"), false, "master off")
ladder.set_harden_master(true)
ok(ladder.set_harden("nope", true) == nil, "unknown site rejected")
ladder.define{ id = "h.nokey", stages = { ladder.llm(function() end) } }
ok(select(2, ladder.set_harden("h.nokey", true)) ~= nil, "a site with no key cannot be hardened")

-- confirm() from a caller with ground truth
reset()
ladder.rand = function() return 1 end
ladder.set_number("h.site", "sample", 0)
local _, m = ladder.run("h.site", { k = "gt" })
for _ = 1, 3 do ladder.confirm(m, true) end
eq(ladder.memo_stats("h.site").promoted, 1, "confirm() promotes without a sample")
ladder.confirm(m, false)
eq(ladder.memo_stats("h.site").entries, 0, "a refutation removes the case")

-- persistence: the memo survives a fresh in-memory state
reset()
for i = 1, 3 do ladder.run("h.site", { k = "p" }) end
local saved = kv["ladder.memo.h.site"]
ok(type(saved) == "string" and saved:find("p", 1, true), "memo written to kv")
ladder.reset(); define(); ladder.rand = function() return 1 end
eq(ladder.memo_stats("h.site").promoted, 1, "memo reloaded from kv")

-- command surface
reset()
ok(harden.command(""):find("h.site", 1, true), "describe lists keyed sites")
ok(harden.command("off h.site"):find("h.site", 1, true), "off <site>")
eq(ladder.harden_enabled("h.site"), false, "command switched the site off")
harden.command("on h.site")
harden.command("clear h.site")
ok(harden.command("obs 5"):find("min_obs=5", 1, true), "obs sets the threshold")
harden.command("obs 3")
ok(harden.command("clear nope"):find("unknown"), "clear rejects an unknown site")
ok(harden.command("bogus"):find("usage"), "usage on nonsense")

-- workflow tier tags
do
  eq(workflow.tier_of("model.interpret"), "llm", "model.* is llm")
  eq(workflow.tier_of("judge.decide"), "jev", "judge.* is jev")
  eq(workflow.tier_of("fs.read"), "code", "everything else is code")
  ok(workflow.set_tier("custom.thing", "llm"), "set_tier accepts a tier")
  eq(workflow.tier_of("custom.thing"), "llm", "declared tier wins")
  ok(workflow.set_tier("x", "bogus") == nil, "set_tier refuses a bad tier")
  local t = harden.tiers({ invocations = { { id = "a", tier = "code" }, { id = "m", tier = "llm" },
    { id = "m", tier = "llm" }, { id = "j", tier = "jev" } } })
  eq(t.code, 1, "tiers counts code"); eq(t.llm, 2, "tiers counts llm"); eq(t.jev, 1, "tiers counts jev")
  eq(#t.residual, 1, "residual lists each llm capability once")
end

-- a real workflow run records the tier on its invocations
do
  local cap, invoke = require("capability"), require("invoke")
  assert(cap.register({ id = "hd.plain", version = "1", effect = "pure" }, function() return 1 end))
  assert(cap.register({ id = "model.hd", version = "1", effect = "pure" }, function() return 2 end))
  assert(workflow.register{ id = "hd-wf", version = "1",
    capabilities = { ["hd.plain"] = "1", ["model.hd"] = "1" },
    run = function(ctx) ctx:call("hd.plain", {}); ctx:call("model.hd", {}); return true end })
  local authority = invoke.context{ state = { mode = "auto", guards = false } }
  local run = assert(workflow.start("hd-wf", { authority = authority }))
  local snap = run:snapshot()
  eq(snap.invocations[1].tier, "code", "plain capability recorded as code")
  eq(snap.invocations[2].tier, "llm", "model capability recorded as llm")
  local t = harden.tiers(snap)
  eq(t.llm, 1, "harden.tiers reads a real snapshot")
end

-- propose: compile aligned traces, name the residual decision, register its jev site
do
  local ast, align = require("mining.ast"), require("mining.align")
  local function fixture(id, person)
    local source = ([[return {run=function(ctx)
 local replies=ctx:call('compile.replies',{query='historical-secret'})
 local interpretation=ctx:call('compile.interpret',{replies=replies.result,expected='%s'})
 if #interpretation.result.missing > 0 then
  return {missing=interpretation.result.missing,filename='historical-file'}
 end
 return {missing={}}
 end}]]):format(person)
    local index = assert(ast.index(source, '1'))
    local trace = { id = id, scope = 'compile-fixture', revision = '1', code_hash = index.source_hash, events = {} }
    local function event(kind, cid, payload)
      trace.events[#trace.events + 1] = { event_id = id .. ':' .. #trace.events + 1, kind = kind, run_id = id, correlation_id = cid, payload = payload }
    end
    for i, name in ipairs({ 'compile.replies', 'compile.interpret' }) do
      event('invocation.start', id .. i, { name = name, args = { private = 'historical-secret' } })
      event('invocation.admitted', id .. i, { descriptor = { id = name, version = '1', target = 'local', effect = 'pure' } })
      event('invocation.terminal', id .. i, { status = 'succeeded', result = {} })
    end
    event('observation.dataflow', nil, { source = 'explicit_annotation', links = { producer = id .. 1, consumer = id .. 2, output = '', input = '/replies' } })
    local parameters, sites = {}, {}
    for _, node in ipairs(index.nodes) do
      if node.kind == 'string' then
        local value = index.source:sub(node.span.start_byte, node.span.end_byte - 1)
        if value == "'historical-secret'" then parameters[node.id] = 'query'
        elseif value == "'historical-file'" then parameters[node.id] = 'filename'
        elseif value == "'" .. person .. "'" then parameters[node.id] = 'expected' end
      elseif node.kind == 'function_call' then sites[#sites + 1] = node.id end
    end
    return trace, index, parameters, sites
  end
  local a, ai, ap, ac = fixture('a', 'historical-Ada')
  local b, bi, bp, bc = fixture('b', 'historical-Ben')
  local aligned = assert(align.compare({ a, b }, { ai, bi }))
  reset()
  local cand, err = harden.propose(aligned, {
    ast_indexes = { ai, bi }, parameters = { ap, bp }, call_sites = { ac, bc },
    residual_capabilities = { ['compile.interpret'] = true },
    jev = { ['compile.interpret'] = { state = function(c) return c.text end,
      questions = { q = { kind = 'noul', instructions = 'complete' } },
      map = function(x) return x.q.noul >= 0.5 end } },
    call = { ['compile.interpret'] = function() return false end },
  })
  ok(cand ~= nil, 'propose compiles a candidate: ' .. tostring(err and err.code))
  if cand then
    eq(cand.manifest.activation_eligible, false, 'proposed candidate is inactive')
    eq(cand.tiers.llm, 1, 'one residual model decision named')
    eq(cand.tiers.residual[1], 'compile.interpret', 'it is the interpret capability')
    eq(cand.ladder_sites[1], 'wf.compile.interpret', 'a jev site is registered for it')
    ok(ladder.site('wf.compile.interpret') ~= nil, 'the site exists')
    eq(workflow.tier_of('compile.interpret'), 'llm', 'the residual capability is now tagged llm')
    local site = ladder.site('wf.compile.interpret')
    eq(site.stages[1].tier, 'jev', 'rung one is jev')
    eq(site.stages[2].tier, 'llm', 'rung two is the model capability')
  end
  local bad, e2 = harden.admit({ source = 'x', source_hash = 'y' }, { schema_version = 1 }, nil, 'id', '1')
  ok(bad == nil and e2 ~= nil, 'admit refuses a candidate without evidence')
end

io.write(string.format("harden: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
