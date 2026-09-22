-- Privileged, project-scoped monitoring. Host assessments are evidence, never Lua authority.
local M={}
local json,identity=require('json'),require('learning.identity')
local function fail(code)error({code=code},0)end
local function must(v)if v==nil or v==false then fail('monitor_storage_unavailable')end;return v end
local function protect(fn)local ok,a,b=pcall(fn);if ok then return a,b end;return nil,type(a)=='table' and a or {code='monitor_error',detail=tostring(a)}end
local function text(v)return type(v)=='string' and #v>0 and #v<=512 end
local function copy(v,seen)if type(v)~='table'then return v end;seen=seen or {};if seen[v]then return seen[v]end;local out={};seen[v]=out;for k,x in pairs(v)do out[k]=copy(x,seen)end;return out end
local function finite(v)return type(v)=='number' and v==v and v>=0 and v<math.huge end
local function lower(k,n,z)if n==0 then return 0 end;local p=k/n;return math.max(0,(p+z*z/(2*n)-z*math.sqrt(p*(1-p)/n+z*z/(4*n*n)))/(1+z*z/n))end
function M.open(o)
 return protect(function()
  assert(type(o)=='table' and o.db and text(o.project) and o.registry and type(o.assess)=='function','monitor_configuration_required')
  local p={window=64,min_samples=3,failure_rate=.2,unknown_rate=.5,z=1.96,cost_ratio=1.5,cost_max=1000,cost_unit='host_cost_units',alpha=.05,max_runs=10000,max_groups=256}
  for k,v in pairs(o.policy or {})do assert(p[k]~=nil,'monitor_policy_unknown');p[k]=v end
  for _,k in ipairs({'window','min_samples','max_runs','max_groups'})do assert(finite(p[k]) and p[k]%1==0 and p[k]>=1 and p[k]<=100000,'monitor_policy_invalid')end
  assert(p.min_samples<=p.window and finite(p.failure_rate) and p.failure_rate<=1 and finite(p.unknown_rate) and p.unknown_rate<=1 and finite(p.z) and p.z>0 and finite(p.cost_ratio) and p.cost_ratio>1 and finite(p.cost_max) and p.cost_max>0 and text(p.cost_unit) and finite(p.alpha) and p.alpha>0 and p.alpha<1,'monitor_policy_invalid')
  local db=o.db;local m={project=o.project}
  local owner=require('evidence').id('monitor-owner')
  must(db:exec([[CREATE TABLE IF NOT EXISTS learning_health(project TEXT,id TEXT,version TEXT,body TEXT NOT NULL,PRIMARY KEY(project,id,version));
CREATE TABLE IF NOT EXISTS learning_health_pending(project TEXT,run TEXT,id TEXT,version TEXT,owner TEXT,PRIMARY KEY(project,run));
CREATE TABLE IF NOT EXISTS learning_health_seen(project TEXT,run TEXT,PRIMARY KEY(project,run));]]))
  local function rows(sql,args)return must(db:query(sql,args))end
  local function run(sql,args)return must(db:run(sql,args))end
  local function get(id,v)local r=rows('SELECT body FROM learning_health WHERE project=? AND id=? AND version=?',{o.project,id,v})[1];return r and json.decode(r.body) or {id=id,version=v,samples={},total=0}end
  local function save(h)run('INSERT INTO learning_health VALUES(?,?,?,?) ON CONFLICT(project,id,version) DO UPDATE SET body=excluded.body',{o.project,h.id,h.version,must(json.encode(h))})end
  local function stats(samples,variant,deps)
   local s={n=0,failed=0,unknown=0,cost_n=0,cost_sum=0,latency_n=0,latency_sum=0}
   for _,x in ipairs(samples)do if x.variant==variant and x.dependencies==deps then
    s.n=s.n+1;if x.classification=='failed'then s.failed=s.failed+1 elseif x.classification=='unknown'then s.unknown=s.unknown+1 end
    if finite(x.cost) and x.cost<=p.cost_max and x.cost_unit==p.cost_unit then s.cost_n=s.cost_n+1;s.cost_sum=s.cost_sum+x.cost end
    if x.latency_ms then s.latency_n=s.latency_n+1;s.latency_sum=s.latency_sum+x.latency_ms end
   end end
   s.failure_lower=lower(s.failed,s.n,p.z);s.unknown_lower=lower(s.unknown,s.n,p.z)
   s.verified=s.n-s.failed-s.unknown
   s.cost_per_verified=s.verified>0 and s.cost_sum/s.verified or nil
   s.cost_coverage=s.cost_n==s.n and 'complete' or 'incomplete'
   s.cost_mean=s.cost_n>0 and s.cost_sum/s.cost_n or nil
   s.cost_radius=s.cost_n>0 and p.cost_max*math.sqrt(math.log(4/p.alpha)/(2*s.cost_n)) or nil
   if s.n>0 and s.cost_n==s.n then
    local radius=math.sqrt(math.log(4/p.alpha)/(2*s.n));local rate=s.verified/s.n
    s.cost_per_verified_lower=math.max(0,s.cost_mean-s.cost_radius)/math.min(1,rate+radius)
    if rate>radius then s.cost_per_verified_upper=(s.cost_mean+s.cost_radius)/(rate-radius)end
   end
   s.cost_unit=p.cost_unit;return s
  end
  local function retained(h)
   require('evidence').assert_scope(o.project)
   for _,sample in ipairs(h.samples)do if sample.source_ref then require('evidence').assert_run(sample.source_ref)end end
  end
  local function apply(h)
   if h.quarantine then
    local v,e=o.registry:get(h.id,h.version);if not v then error(e,0)end
    if v.state~='quarantined' then local ok,why=o.registry:set_state(h.id,h.version,'quarantined','monitor:'..h.quarantine);if not ok then error(why,0)end end
   end
  end
  local function key(id,v,run_id)return identity.hash({id=id,version=v,run=run_id})end
  local function capacity()
   local n=rows('SELECT COUNT(*) AS n FROM learning_health_seen WHERE project=?',{o.project})[1].n
   local pending=rows('SELECT COUNT(*) AS n FROM learning_health_pending WHERE project=?',{o.project})[1].n
   if n+pending>=p.max_runs then fail('monitor_capacity_exhausted')end
  end
  function m:begin(id,v,run_id)
   return protect(function()
    must(db:exec('BEGIN IMMEDIATE'))
    local ok,result=pcall(function()
     capacity()
     local k=key(id,v,run_id)
     if #rows('SELECT run FROM learning_health_seen WHERE project=? AND run=?',{o.project,k})>0 or #rows('SELECT run FROM learning_health_pending WHERE project=? AND run=?',{o.project,k})>0 then fail('monitor_run_already_observed_or_pending')end
     local groups=rows('SELECT id,version FROM learning_health WHERE project=? UNION SELECT id,version FROM learning_health_pending WHERE project=?',{o.project,o.project})
     local exists=false;for _,g in ipairs(groups)do if g.id==id and g.version==v then exists=true end end
     if not exists and #groups>=p.max_groups then fail('monitor_capacity_exhausted')end
     run('INSERT INTO learning_health_pending VALUES(?,?,?,?,?)',{o.project,k,id,v,owner});return true
    end)
    if not ok then pcall(db.exec,db,'ROLLBACK');error(result,0)end
    if not db:exec('COMMIT')then pcall(db.exec,db,'ROLLBACK');fail('monitor_storage_unavailable')end
    return true
   end)
  end
  function m:abort(id,v,run_id)
   return protect(function()run('DELETE FROM learning_health_pending WHERE project=? AND run=? AND owner=?',{o.project,key(id,v,run_id),owner});return true end)
  end
  function m:admit(id,v,run_id)
   return protect(function()
    local h=get(id,v);retained(h);if h.quarantine then fail('monitor_quarantined')end
    if #rows('SELECT run FROM learning_health_pending WHERE project=? AND owner<>?',{o.project,owner})>0 then fail('monitor_recovery_required')end
    local own=run_id and rows('SELECT run FROM learning_health_pending WHERE project=? AND run=? AND owner=?',{o.project,key(id,v,run_id),owner})[1]
    if not own then capacity()end
    return true
   end)
  end
  function m:observe(snapshot)
   return protect(function()
    local l=snapshot.learning
    if type(l)~='table' or l.project~=o.project or not text(l.id) or not text(l.version) or not text(l.run_id) then fail('monitor_identity_invalid')end
    if snapshot.status=='created' or snapshot.status=='running' or snapshot.status=='suspended' then fail('monitor_not_terminal')end
    if not ({succeeded=true,failed=true,cancelled=true,denied=true,unavailable=true,uncertain=true})[snapshot.status] then fail('monitor_not_terminal')end
    require('evidence').assert_scope(o.project)
    require('evidence').assert_run(snapshot.id)
    local runkey=identity.hash({id=l.id,version=l.version,run=l.run_id})
    if #rows('SELECT run FROM learning_health_seen WHERE project=? AND run=?',{o.project,runkey})>0 then local h=get(l.id,l.version);retained(h);apply(h);run('DELETE FROM learning_health_pending WHERE project=? AND run=?',{o.project,runkey});return {duplicate=true,quarantined=h.quarantine~=nil}end
    -- The callback receives the actual terminal snapshot, including current resolved inputs.
    local ok,a=pcall(o.assess,copy(snapshot));if not ok or type(a)~='table' then a={assessment_error=true}end
    local ver=type(a.verifier)=='table' and a.verifier or {}
    local observed=snapshot.evidence and snapshot.evidence.coverage=='observed' and text(snapshot.evidence.terminal_event_id)
    local classification='unknown'
    if snapshot.status~='succeeded' and snapshot.status~='cancelled' then classification='failed'
    elseif snapshot.status~='cancelled' and ver.passed==false and text(ver.ref) then classification='failed'
    elseif snapshot.status=='succeeded' and observed and ver.passed==true and text(ver.ref) and not snapshot.effects_incomplete then classification='verified'end
    local stale
    for _,key in ipairs({'applicability','dependencies'})do local x=a[key];if type(x)=='table' and x.current==false and text(x.ref)then stale=key..'_stale'end end
    local variant=text(a.variant) and a.variant or 'unknown'
    local manifest=snapshot.manifest or {}
    local deps=identity.hash({capabilities=manifest.capabilities or {},providers=manifest.providers and manifest.providers.injected or {}})
    local x={run_ref=runkey,terminal_ref=observed and snapshot.evidence.terminal_event_id or nil,coverage=observed and 'observed' or 'incomplete',status=snapshot.status,classification=classification,verifier_ref=text(ver.ref) and ver.ref or nil,variant=variant,dependencies=deps,cohort=l.cohort or 'unknown',source_ref=snapshot.id,error_code=type(snapshot.error)=='table' and snapshot.error.code or nil,remine=classification~='verified' and 'failure_or_unknown' or nil,stale=stale,stale_ref=stale and a[stale:match('^(.-)_stale')].ref or nil,assessment_error=a.assessment_error or nil}
    if type(a.cost)=='table' and a.cost.unit==p.cost_unit and finite(a.cost.value) and a.cost.value<=p.cost_max then x.cost=a.cost.value;x.cost_unit=p.cost_unit end
    if finite(a.latency_ms)then x.latency_ms=a.latency_ms end
    x=require('evidence').redact(x)
    must(db:exec('BEGIN IMMEDIATE'))
    local success,result=pcall(function()
     local h=get(l.id,l.version);retained(h)
     if #rows('SELECT run FROM learning_health_seen WHERE project=? AND run=?',{o.project,runkey})>0 then return {duplicate=true,health=h}end
     if rows('SELECT COUNT(*) AS n FROM learning_health_seen WHERE project=?',{o.project})[1].n>=p.max_runs then fail('monitor_capacity_exhausted')end
     if h.total==0 and rows('SELECT COUNT(*) AS n FROM learning_health WHERE project=?',{o.project})[1].n>=p.max_groups then fail('monitor_capacity_exhausted')end
     h.samples[#h.samples+1]=x;while #h.samples>p.window do table.remove(h.samples,1)end;h.total=h.total+1
     local s=stats(h.samples,variant,deps);h.latest=s;h.policy=copy(p);h.coverage={variant=variant,dependencies=deps,confidence='Wilson score failure bounds; Hoeffding bounded-cost mean bounds',assumption='independent representative observations; host-assessed costs bounded by cost_max',missing_independent_verifier=classification=='unknown'}
     local reason=stale
     if s.n>=p.min_samples then
      if s.failure_lower>=p.failure_rate then reason=reason or 'verification_or_execution_regression'end
      if s.unknown_lower>=p.unknown_rate then reason=reason or 'unknown_outcomes'end
     end
     if variant~='unknown' and l.baseline and l.baseline~=l.version then
      -- Versions may intentionally pin different capability revisions; compare only same task variant.
      local base=get(l.id,l.baseline);local compatible={}
      for _,b in ipairs(base.samples)do if b.variant==variant then local c={};for k,v in pairs(b)do c[k]=v end;c.dependencies=deps;compatible[#compatible+1]=c end end
      local bs=stats(compatible,variant,deps);h.comparison={baseline=l.baseline,baseline_stats=bs,canary_stats=s,variant=variant}
      if s.cost_n>=p.min_samples and bs.cost_n>=p.min_samples and s.cost_per_verified_lower and bs.cost_per_verified_upper and s.cost_per_verified_lower>p.cost_ratio*bs.cost_per_verified_upper then reason=reason or 'cost_regression'end
     end
     h.quarantine=h.quarantine or reason;save(h);run('INSERT INTO learning_health_seen VALUES(?,?)',{o.project,runkey});run('DELETE FROM learning_health_pending WHERE project=? AND run=?',{o.project,runkey});return {health=h}
    end)
    if success then local committed=db:exec('COMMIT');if not committed then pcall(db.exec,db,'ROLLBACK');fail('monitor_storage_unavailable')end else pcall(db.exec,db,'ROLLBACK');error(result,0)end
    apply(result.health)
    return {duplicate=result.duplicate or false,quarantined=result.health.quarantine~=nil,reason=result.health.quarantine,health=result.health}
   end)
  end
  function m:explain(id)
   return protect(function()require('evidence').assert_scope(o.project);local out={project=o.project,id=id,policy=copy(p),versions={},pending=rows('SELECT id,version,run FROM learning_health_pending WHERE project=?',{o.project}),retention={window=p.window,max_runs=p.max_runs,max_groups=p.max_groups,capacity_behavior='refuse admission; explicit archival required'}};for _,r in ipairs(rows('SELECT body FROM learning_health WHERE project=? AND id=?',{o.project,id}))do local h=json.decode(r.body);retained(h);out.versions[#out.versions+1]=h end;return out end)
  end
  local ok,why=o.registry:monitor(m);if not ok then error(why,0)end
  return m
 end)
end
return M
