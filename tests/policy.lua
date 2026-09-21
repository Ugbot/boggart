local policy = require "policy"
local passed = 0
local function check(value, name)
  assert(value, name); passed = passed + 1
end
local function compile(scopes) return assert(policy.compile(scopes)) end
local read = { id = "files.read", version = "1", effect = "read",
  resources = function(args) return { path = args.path } end }
local function decide(scopes, path, usage)
  return policy.decide(compile(scopes), read, { path = path or "/project/a" }, usage)
end
local root = { id = "root", revision = 1, capabilities = { allow = { "*" } } }
local deny = { id = "deny", revision = 1, capabilities = { deny = { "files.read" } } }
check(decide({root}).verdict == "allow", "explicit root grant")
check(decide({root, deny}).verdict == "deny", "child cannot defeat deny")
check(decide({deny, root}).verdict == "deny", "scope order independent")
check(decide({}).verdict == "deny", "no implicit grant")
check(decide({root, {id="empty", revision=1, capabilities={allow={}}}}).verdict == "deny", "empty allow denies all")
local a = {id="a", revision=1, resources={path={evaluator="prefix", allow={"/project/"}}}}
local b = {id="b", revision=1, resources={path={allow={"/other/a"}}}}
check(decide({root,a,b}).verdict == "deny", "disjoint resource constraints deny")
check(decide({root,a}).verdict == "allow", "host-extracted resource matches")
check(decide({root,a}, "/project-other/a").verdict == "deny", "prefix does not widen slash boundary")
local absent = policy.decide(compile({root,a}), {id="files.read",version="1",effect="read"}, {})
check(absent.verdict == "deny", "missing resource evaluator denies")
check(policy.decide(compile({root}), {}, {}).verdict == "deny", "unknown descriptor denies")
local require_approval = {id="approval",revision=1,approval=true}
check(decide({root,require_approval}).verdict == "ask", "approval accumulates")
check(decide({root,require_approval,deny}).verdict == "deny", "denial outranks approval")
local cap = {id="cap",revision=2,limits={tokens=20},quotas={{id="requests",metric="calls",limit=2,window_seconds=60}}}
local child = {id="child",revision=1,limits={tokens=100},quotas={{id="requests",metric="calls",limit=5,window_seconds=60}}}
local result = decide({root,cap,child}, nil, {tokens=21})
check(result.verdict == "deny", "least hard ceiling wins")
check(#result.obligations.quotas == 2, "all scope quota buckets retained")
check(result.obligations.limits.tokens == 20, "ceiling is visible")
check(result.obligations.quotas[1].scope_id ~= result.obligations.quotas[2].scope_id, "same named quota cannot replace ancestor")
local c = compile({root,cap})
root.capabilities.allow[1] = "nothing"
cap.limits.tokens = 1000
local copy = policy.describe(c)
copy.scopes[1].id = "changed"
rawset(c, "scopes", {})
check(policy.decide(c,read,{path="/project/a"},{tokens=21}).verdict == "deny", "compiled state cannot be widened via mutations")
check(policy.decide(c,read,{path="/project/a"},{tokens=1}).verdict == "allow", "source allow snapshot retained")
local first = policy.decide(c,read,{path="/project/a"})
first.obligations.limits.tokens = 1000
check(policy.decide(c,read,{path="/project/a"},{tokens=21}).verdict == "deny", "decision does not leak internal state")
for _, bad in ipairs({
  {id="bad",revision=1,limits={tokens=-1}},
  {id="bad",revision=1,limits={tokens=0/0}},
  {id="bad",revision=1,limits={tokens=math.huge}},
  {id="bad",revision=1,resources={path={evaluator="mystery",allow={"x"}}}},
  {id="bad",revision=1,quotas={{id="q",metric="calls",limit=2,window_seconds=0}}},
  {id="bad",revision=1,typo_grant=true},
  {id="bad",revision=1,capabilities={allow={[2]="*"}}},
}) do
  local value, err = policy.compile({bad})
  check(value == nil and type(err) == "string", "malformed policy rejected")
end
check(policy.compile({a,a}) == nil, "duplicate scope identity rejected")
check(policy.decide({},read,{}).verdict == "deny", "forged compiled handle rejected")
check(policy.decide(c,read,{}, {tokens=-1}).verdict == "deny", "negative usage denied")
check(policy.decide(c,read,{}, {tokens=0/0}).verdict == "deny", "NaN usage denied")
local c2 = compile({{id="root",revision=1,capabilities={allow={"*"}}},require_approval})
local c3 = compile({require_approval,{id="root",revision=1,capabilities={allow={"*"}}}})
check(policy.describe(c2).revision == policy.describe(c3).revision, "canonical revision order")
local hostile = setmetatable({}, {__index=function() error("hostile index") end,
  __pairs=function() error("hostile pairs") end})
for _, call in ipairs({
  function() return policy.decide(c,hostile,{}) end,
  function() return policy.decide(c,read,hostile) end,
  function() return policy.decide(c,read,{},hostile) end,
  function() return policy.decide(c,read,false) end,
  function() return policy.decide(c,read,{},false) end,
}) do
  local ok, value = pcall(call)
  check(ok and value.verdict == "deny", "malformed decision input denies without raising")
end
print(string.format("policy: %d passed", passed))
