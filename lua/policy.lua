-- Restrictive, declarative policy composition. Compiled handles contain no
-- authority: their private snapshots are held here, never in caller tables.
local M = {}
local compiled = setmetatable({}, { __mode = "k" })

local function finite(n)
  return type(n) == "number" and n == n and n >= 0 and n < math.huge
end
local function nonempty(s) return type(s) == "string" and #s > 0 end
local function plain(t) return type(t) == "table" and getmetatable(t) == nil end
local function copy(v, seen)
  if type(v) ~= "table" then
    assert(type(v) == "string" or type(v) == "number" or type(v) == "boolean" or v == nil,
      "policy values must be plain data")
    return v
  end
  assert(getmetatable(v) == nil, "policy tables cannot have metatables")
  seen = seen or {}
  assert(not seen[v], "cyclic policy")
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    assert(type(k) == "string" or type(k) == "number", "invalid policy key")
    out[k] = copy(x, seen)
  end
  seen[v] = nil
  return out
end
local function fields(t, allowed)
  assert(type(t) == "table", "expected policy table")
  for k in pairs(t) do assert(allowed[k], "unknown policy field: " .. tostring(k)) end
end
local function list(t, validate)
  assert(type(t) == "table", "expected policy list")
  local count = 0
  for k, v in pairs(t) do
    assert(type(k) == "number" and k >= 1 and k % 1 == 0, "invalid list index")
    validate(v); count = count + 1
  end
  for i = 1, count do assert(t[i] ~= nil, "sparse policy list") end
end
local function strings(t)
  list(t, function(s) assert(nonempty(s), "expected nonempty policy string") end)
end
local function constraint(t, resource)
  fields(t, resource and {allow=true,deny=true,evaluator=true} or {allow=true,deny=true})
  if t.allow ~= nil then strings(t.allow) end
  if t.deny ~= nil then strings(t.deny) end
  if resource then
    t.evaluator = t.evaluator or "exact"
    assert(t.evaluator == "exact" or t.evaluator == "prefix", "unknown resource evaluator")
  end
end
local function build(scopes)
  scopes = copy(scopes)
  local ids, limits, quotas = {}, {}, {}
  list(scopes, function(s)
    fields(s, {id=true,revision=true,capabilities=true,resources=true,approval=true,limits=true,quotas=true})
    assert(nonempty(s.id), "scope id required")
    assert(nonempty(s.revision) or (finite(s.revision) and s.revision % 1 == 0), "scope revision required")
    assert(not ids[s.id], "duplicate scope id: " .. s.id)
    ids[s.id] = true
    if s.capabilities ~= nil then constraint(s.capabilities, false) end
    if s.approval ~= nil then assert(type(s.approval) == "boolean", "approval must be boolean") end
    if s.resources ~= nil then
      assert(type(s.resources) == "table", "resources must be a table")
      for field, c in pairs(s.resources) do
        assert(nonempty(field), "resource field required"); constraint(c, true)
      end
    end
    if s.limits ~= nil then
      assert(type(s.limits) == "table", "limits must be a table")
      for metric, ceiling in pairs(s.limits) do
        assert(nonempty(metric) and finite(ceiling), "invalid hard limit")
        limits[metric] = math.min(limits[metric] or math.huge, ceiling)
      end
    end
    local quota_ids = {}
    if s.quotas ~= nil then list(s.quotas, function(q)
      fields(q, {id=true,metric=true,limit=true,window_seconds=true,subject=true})
      assert(nonempty(q.id) and not quota_ids[q.id], "unique quota id required")
      assert(nonempty(q.metric) and finite(q.limit), "invalid quota limit")
      assert(finite(q.window_seconds) and q.window_seconds > 0 and q.window_seconds % 1 == 0,
        "quota window must be positive integer seconds")
      assert(q.subject == nil or nonempty(q.subject), "invalid quota subject")
      quota_ids[q.id] = true
      local entry = copy(q)
      entry.scope_id, entry.scope_revision = s.id, s.revision
      quotas[#quotas + 1] = entry
    end) end
  end)
  table.sort(scopes, function(a,b) return a.id < b.id end)
  table.sort(quotas, function(a,b)
    return a.scope_id == b.scope_id and a.id < b.id or a.scope_id < b.scope_id
  end)
  local revision = {}
  for _, s in ipairs(scopes) do
    local rev = tostring(s.revision)
    revision[#revision + 1] = #s.id .. ":" .. s.id .. #rev .. ":" .. rev
  end
  return {scopes=scopes, revision=table.concat(revision, "/"), limits=limits, quotas=quotas}
end

function M.compile(scopes)
  local ok, state = pcall(build, scopes)
  if not ok then return nil, tostring(state) end
  local handle = setmetatable({}, {__metatable="compiled policy", __newindex=function()
    error("compiled policy is immutable", 2)
  end})
  compiled[handle] = state
  return handle
end

function M.describe(handle)
  local state = compiled[handle]
  if not state then return nil, "invalid compiled policy" end
  return copy(state)
end

local function matches(values, value, evaluator)
  for _, v in ipairs(values or {}) do
    if evaluator == "capability" and v == "*" then return true end
    if evaluator == "prefix" and value:sub(1, #v) == v then return true end
    if v == value then return true end
  end
  return false
end
local function permitted(c, value, evaluator)
  return (c.allow == nil or matches(c.allow, value, evaluator))
    and not matches(c.deny, value, evaluator)
end

function M.decide(handle, descriptor, args, usage)
  local state = compiled[handle]
  local out = {verdict="allow", reasons={}, obligations={limits={},quotas={},approvals={}}}
  local function deny(reason)
    out.verdict = "deny"; out.reasons[#out.reasons+1] = reason
  end
  if not state then deny("invalid compiled policy"); return out end
  out.policy_revision = state.revision
  out.obligations.limits, out.obligations.quotas = copy(state.limits), copy(state.quotas)
  if not plain(descriptor) or not nonempty(descriptor.id) or not nonempty(descriptor.version)
    or not ({pure=true,read=true,write=true,unknown=true})[descriptor.effect] then
    deny("unknown capability descriptor"); return out
  end
  if (args ~= nil and not plain(args)) or (usage ~= nil and not plain(usage)) then
    deny("invalid arguments or usage"); return out
  end
  usage = usage or {}
  for metric, amount in pairs(usage) do
    if not nonempty(metric) or not finite(amount) then deny("invalid usage"); return out end
  end
  for metric, ceiling in pairs(state.limits) do
    if (usage[metric] or 0) > ceiling then deny("hard limit exceeded: " .. metric) end
  end
  local needs_resources = false
  for _, s in ipairs(state.scopes) do
    if s.resources and next(s.resources) then needs_resources = true end
  end
  local resources = {}
  if needs_resources then
    if type(descriptor.resources) ~= "function" then
      deny("capability has no resource evaluator"); return out
    end
    local ok, values = pcall(descriptor.resources, args or {})
    if not ok or type(values) ~= "table" or getmetatable(values) ~= nil then
      deny("resource evaluation failed"); return out
    end
    resources = values
  end
  local granted = false
  for _, s in ipairs(state.scopes) do
    local caps = s.capabilities
    if caps then
      if caps.allow ~= nil then granted = true end
      if not permitted(caps, descriptor.id, "capability") then deny("capability restricted by " .. s.id) end
    end
    for field, c in pairs(s.resources or {}) do
      local value = resources[field]
      if type(value) ~= "string" or not permitted(c, value, c.evaluator) then
        deny("resource " .. field .. " restricted by " .. s.id)
      end
    end
    if s.approval then out.obligations.approvals[#out.obligations.approvals+1] = s.id end
  end
  if not granted then deny("no capability grant") end
  if descriptor.effect == "unknown" then
    out.obligations.approvals[#out.obligations.approvals+1] = "unknown-effect"
  end
  if out.verdict ~= "deny" and #out.obligations.approvals > 0 then out.verdict = "ask" end
  table.sort(out.reasons)
  return out
end

return M
