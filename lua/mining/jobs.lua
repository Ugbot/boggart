-- Trusted-host scheduler. Workers only analyze evidence; admission stays in Lua.
local json,uv=require('json'),require('uv')
local evidence,retention=require('evidence'),require('evidence_retention')
local invoke,policy=require('invoke'),require('policy')
local hash=require('workflow').hash
local M={}
local VERSION=1
local MAX_RUNS,MAX_EVENTS,MAX_BYTES=32,64,32768
local WORKER=[[
 local p=json.decode(worker.arg)
 local ok,result=pcall(function()
  local indexes,parameters,source_count={},{},0
  for i,tr in ipairs(p.traces)do
   if tr.code then
    indexes[i]=assert(require('mining.ast').index(tr.code.source,tr.code.version))
    parameters[i]={}
    for _,parameter in ipairs(tr.code.parameters or {})do parameters[i][parameter.node]=parameter.key end
    source_count=source_count+1
   end
  end
  if source_count>0 and source_count~=#p.traces then return {error='mixed_source_association'} end
  local a,e=require('mining.align').compare(p.traces,source_count>0 and indexes or nil)
  if not a then return {error=e.code} end
  local c,why=require('mining.compile').candidate(a,source_count>0 and {ast_indexes=indexes,parameters=parameters} or nil)
  if not c then return {error=why.code} end
  local contract={schema_version=c.manifest.schema_version,compiler=c.manifest.compiler,
   capabilities=c.manifest.capabilities,limits=c.manifest.limits,required_context={},descriptors={},verifiers=c.verifiers}
  for _,required in ipairs(c.required_context)do
   contract.required_context[#contract.required_context+1]={key=required.key,required=required.required,origin=required.origin}
  end
  for _,step in ipairs(a.traces[1].steps)do
   local d=step.descriptor
   contract.descriptors[#contract.descriptors+1]={id=d.id,version=d.version,target=d.target,effect=d.effect}
  end
  return {candidate=c,contract=contract}
 end)
 return json.encode(ok and result or {error='mining_analysis_failed'})
]]
local function checked(v,e) assert(v~=nil and v~=false,e or 'mining_database');return v end
local function protect(fn)
 local ok,v=pcall(fn);if ok then return v end
 return nil,{code=type(v)=='table' and v.code or tostring(v)}
end
local function integer(v,lo,hi) return type(v)=='number' and v%1==0 and v>=lo and v<=hi end
local function text(v,n) return type(v)=='string' and #v>0 and #v<=n end
local function encode(v) return checked(json.encode(v)) end
local function copy(v) return json.decode(encode(v)) end
local function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a)do if not equal(v,b[k]) then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function canonical(v)
 if type(v)~='table' then return encode(v) end
 local keys={};for key in pairs(v)do keys[#keys+1]=key end
 table.sort(keys,function(a,b)return type(a)==type(b) and a<b or type(a)<type(b) end)
 local out={};for _,key in ipairs(keys)do out[#out+1]=canonical(key)..':'..canonical(v[key]) end
 return '{'..table.concat(out,',')..'}'
end
local function owner_alive(owner)
 local pid=tonumber(owner:match('^(%d+)/'))
 if not pid then return true end
 local ok,err=uv.kill(pid,0)
 return ok~=nil or not tostring(err):find('ESRCH',1,true)
end
local function transaction(db,fn)
 checked(db:exec('BEGIN IMMEDIATE'))
 local ok,v=pcall(fn)
 if ok then local yes,e=db:exec('COMMIT');if yes then return v end;v=e end
 pcall(db.exec,db,'ROLLBACK');error(v,0)
end
function M.open(o)
 return protect(function()
  assert(type(o)=='table' and o.db and o.ledger and o.policy and o.authority,'mining_configuration_required')
  local db=o.db
  checked(db:exec('PRAGMA busy_timeout=0'))
  retention.ensure(db)
  checked(db:exec([[
CREATE TABLE IF NOT EXISTS mining_jobs(id TEXT PRIMARY KEY,version INTEGER NOT NULL,body TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS mining_jobs_queue ON mining_jobs(json_extract(body,'$.status'),json_extract(body,'$.mode'),id);
CREATE TABLE IF NOT EXISTS mining_pairs(id TEXT PRIMARY KEY,body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS mining_candidates(id TEXT PRIMARY KEY,scope TEXT NOT NULL,body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS mining_slot(id INTEGER PRIMARY KEY CHECK(id=1),owner TEXT NOT NULL,expires INTEGER NOT NULL);
INSERT OR IGNORE INTO mining_slot VALUES(1,'',0);
]]))
  local engine={}
  local live,foreground,timer,pending=nil,false,nil,nil
  local function rows(sql,args)return checked(db:query(sql,args))end
  local function run(sql,args)return checked(db:run(sql,args))end
  local function get(id)
   local r=rows('SELECT version,body FROM mining_jobs WHERE id=?',{id})[1]
   assert(r,'mining_job_missing');assert(r.version==VERSION,'mining_version_unavailable');return json.decode(r.body)
  end
  local function save(j)run('UPDATE mining_jobs SET body=? WHERE id=?',{encode(j),j.id})end
  local function arm_timer()
   if timer then return end
   timer=uv.new_timer();uv.timer_start(timer,5,5,function() engine:tick() end);uv.unref(timer)
  end
  local function release_pending()
   local claim=pending
   if claim.reserved then checked(o.ledger:settle(claim.owner,nil,'uncertain')) end
   transaction(db,function()
    run("UPDATE mining_slot SET owner='',expires=0 WHERE id=1 AND owner=?",{claim.owner})
    if claim.failure then
     local j=get(claim.job)
     if j.status=='queued' then j.status='failed';j.error=claim.failure;save(j) end
    end
   end)
   pending=nil
   if timer then uv.timer_stop(timer);uv.close(timer);timer=nil end
   return claim.response
  end
  local function authorized(j)
   local s=(o.scopes or {})[j.scope]
   assert(s and s.enabled==true,'mining_scope_denied')
   assert(s.revision==j.authority_revision,'mining_authority_changed')
   local correlation=invoke.correlation()
   assert(not correlation.scope or correlation.scope==j.scope,'mining_scope_mismatch')
   retention.assert_scope(db,j.scope)
   local authority=invoke.restrict_durable(o.authority,j.restrictions)
   assert(equal(j.policy_scopes,assert(policy.describe(o.policy)).scopes),'mining_policy_changed')
   local effective=o.policy
   local d={id='mining.analyze',version='1',target='local',effect='read',resources=function()return {scope=j.scope}end}
   local usage={analysis_ms=j.budget.wall_ms,tokens=0,cost=0,calls=1}
   assert(policy.decide(effective,d,{},usage).verdict=='allow','mining_policy_denied')
   for _,restrictions in ipairs({invoke.durable_restrictions(authority)})do
    for _,r in ipairs(restrictions)do
     assert(not r.allow or require('tools').allowed(r.allow,d.id),'mining_inherited_allow_denied')
     assert(require('perm').decide(d.id,{scope=j.scope},r.state)=='allow','mining_inherited_permission_denied')
     if r.scopes then
      local inherited=assert(policy.compile(r.scopes))
      assert(#assert(policy.describe(inherited)).quotas==0,'mining_inherited_quotas_unsupported')
      assert(policy.decide(inherited,d,{},usage).verdict=='allow','mining_inherited_policy_denied')
     end
    end
   end
   return effective
  end
  local function registered(code,scope)
   local registered=(o.sources or {})[code.hash]
   assert(registered and registered.scope==scope and registered.version==code.version and registered.revision==code.revision,'mining_source_registry_unavailable')
   assert(type(registered.source)=='string' and #registered.source<=MAX_BYTES and hash(registered.source)==code.hash,'mining_source_registry_changed')
   assert(equal(registered.parameters or {},code.parameters or {}),'mining_parameters_changed')
   assert(#(registered.parameters or {})<=256,'mining_parameter_limit')
   for _,p in ipairs(registered.parameters or {})do assert(integer(p.node,1,12000) and text(p.key,128),'mining_invalid_parameter') end
   return registered
  end
  local function snapshot(id,scope)
   assert(retention.assert_run(db,id)==scope,'mining_source_scope')
   retention.assert_scope(db,scope)
   local r=rows('SELECT seq,length(body) AS bytes FROM evidence_events WHERE run_id=? ORDER BY seq LIMIT 65',{id})
   assert(#r>0 and #r<=MAX_EVENTS,'mining_source_limit')
   local bytes=0;for _,x in ipairs(r)do bytes=bytes+x.bytes end
   assert(bytes<=MAX_BYTES,'mining_source_limit')
   local events=assert(require('mining.recognize').native(id,scope,db))
   local bodies=rows('SELECT body FROM evidence_events WHERE run_id=? ORDER BY seq LIMIT 65',{id})
   local exact={};for _,x in ipairs(bodies)do exact[#exact+1]=x.body end
   local revision=hash(table.concat(exact,'\n'))
   local code
   for _,event in ipairs(events)do
    if event.kind=='workflow.start' then
     assert(not code,'mining_nested_source_unsupported')
     local identity=event.payload and event.payload.workflow
     assert(identity and identity.source_hash,'mining_source_association_required')
     local entry=(o.sources or {})[identity.source_hash]
     assert(entry and text(entry.revision,128),'mining_source_registry_unavailable')
     code={hash=identity.source_hash,version=identity.version,revision=entry.revision,parameters=copy(entry.parameters or {})}
     registered(code,scope)
    end
   end
   return {id=id,scope=scope,revision=revision,first=r[1].seq,last=r[#r].seq,count=#r,bytes=bytes,code=code},events
  end
  local function source(ref)
   local now,events=snapshot(ref.id,ref.scope)
   assert(now.revision==ref.revision and now.count==ref.count and now.last==ref.last,'mining_source_changed')
   assert(equal(now.code,ref.code),'mining_source_registry_changed')
   local code=ref.code and registered(ref.code,ref.scope)
   return {id=ref.id,scope=ref.scope,revision=ref.revision,source_ref=ref.id,events=events,code_hash=ref.code and ref.code.hash,
    code=code and {source=code.source,version=code.version,parameters=code.parameters or {}}}
  end
  local function pair(j)
   local a,b=j.snapshot[j.i],j.snapshot[j.k]
   return hash(canonical({VERSION,j.scope,a.id,a.revision,a.code or false,b.id,b.revision,b.code or false})),a,b
  end
  local function advance(j,p)
   j.results[#j.results+1]={pair=p.id,candidate_id=p.candidate_id,error=p.error}
   j.k=j.k+1
   if j.k>#j.snapshot then j.i=j.i+1;j.k=j.i+1 end
   j.cursor=j.cursor+1
   j.status=j.i>=#j.snapshot and 'completed' or 'queued'
   save(j)
  end
  function engine:start(spec)
   return protect(function()
    assert(type(spec)=='table' and text(spec.scope,1024) and text(spec.objective,4096),'mining_invalid_job')
    assert(spec.mode=='directed' or spec.mode=='background','mining_invalid_mode')
    assert(type(spec.range)=='table' and #spec.range>=2 and #spec.range<=MAX_RUNS,'mining_range_required')
    local budget=spec.budget or {};for k in pairs(budget)do assert(({ticks=true,wall_ms=true,tokens=true,cost=true})[k],'mining_unknown_budget') end;assert(integer(budget.ticks or 496,1,1000) and integer(budget.wall_ms or 100,1,1000),'mining_invalid_budget')
    assert((budget.tokens or 0)==0 and (budget.cost or 0)==0,'mining_llm_unavailable')
    local s=(o.scopes or {})[spec.scope];assert(s and text(s.revision,128),'mining_scope_denied')
    local j={id=evidence.id('mining-job'),version=VERSION,scope=spec.scope,objective=evidence.redact(spec.objective),mode=spec.mode,
     authority_revision=s.revision,restrictions=invoke.durable_restrictions(o.authority),policy_scopes=assert(policy.describe(o.policy)).scopes,
     budget={ticks=budget.ticks or 496,wall_ms=budget.wall_ms or 100,tokens=0,cost=0},attempts=0,
     i=1,k=2,cursor=0,generation=0,snapshot={},results={},status='queued'}
    local identity=require('quota').identity(o.ledger)
    for _,r in ipairs(j.restrictions)do assert(not r.ledger or not equal(r.ledger,identity),'mining_requires_separate_ledger') end
    authorized(j)
    transaction(db,function()
     local ids,seen={},{};for _,id in ipairs(spec.range)do assert(text(id,256) and not seen[id],'mining_invalid_range');seen[id]=true;ids[#ids+1]=id end
     table.sort(ids)
     for _,id in ipairs(ids)do j.snapshot[#j.snapshot+1]=snapshot(id,j.scope) end
     run('INSERT INTO mining_jobs VALUES(?,?,?)',{j.id,VERSION,encode(j)})
    end)
    return j.id
   end)
  end
  function engine:status(id)
   return protect(function()
    local j=get(id);authorized(j);j.candidates={}
    for _,result in ipairs(j.results)do if result.candidate_id then
     local row=rows('SELECT body FROM mining_candidates WHERE id=?',{result.candidate_id})[1]
     if row then
      local c=json.decode(row.body);local valid=true
      for _,ref in ipairs(c.sources)do if not pcall(source,ref) then valid=false end end
      if valid then j.candidates[#j.candidates+1]=c else j.invalidated=true end
     end
    end end
    return j
   end)
  end
  function engine:cancel(id)
   return protect(function()
    transaction(db,function()
     local j=get(id);if j.status~='completed' then j.status='cancelled';j.generation=(j.generation or 0)+1;save(j) end
    end)
    if live and live.job==id then worker.kill(live.handle) end
    return true
   end)
  end
  function engine:resume(id)
   return protect(function()return transaction(db,function()
    local j=get(id);authorized(j)
    if j.status=='cancelled' then j.status='queued';save(j) end
    return true
   end)end)
  end
  function engine:schedule(name,when,id)
   return require('triggers').add(name,when,function() self:tick(id) end,{quiet=true})
  end
  function engine:foreground(on) foreground=on==true;return true end
  function engine:set_scope(scope,value) o.scopes=o.scopes or {};o.scopes[scope]=copy(value);return true end
  function engine:background(on)o.background_enabled=on==true;return true end
  function engine:tick(id,budget)
   return protect(function()
    if pending then return release_pending() end
    if live then
     if not live.finished then
      local state=worker.status(live.handle)
      if state=='running' or state=='paused' then
       if uv.hrtime()>=live.deadline then worker.kill(live.handle);live.timed_out=true end
       return {status='running',job_id=live.job}
      end
      local ok,body=worker.join(live.handle)
      live.finished={ok=ok,body=body,elapsed=(uv.hrtime()-live.started)/1000000}
     end
     local work=live
     local ok,body,elapsed=work.finished.ok,work.finished.body,work.finished.elapsed
     local overrun=elapsed>work.wall_ms
     local settlement=checked(o.ledger:settle(work.owner,{analysis_ms=math.max(work.wall_ms,elapsed),tokens=0,cost=0},overrun and 'failure' or 'success'))
     local result=ok and json.decode(body) or {error=work.timed_out and 'mining_time_limit' or 'mining_worker_failed'}
     if overrun or settlement.overrun then result={error='mining_time_limit'} end
     local response=transaction(db,function()
      local slot=rows('SELECT owner FROM mining_slot WHERE id=1')[1]
      if slot.owner~=work.owner then return {status='superseded'} end
      run("UPDATE mining_slot SET owner='',expires=0 WHERE id=1")
      local j=get(work.job)
      j.last_elapsed_ms=elapsed;j.deadline_overrun=overrun
      if j.status~='queued' or (j.generation or 0)~=work.generation then save(j);return {status=j.status} end
      if j.cursor~=work.cursor or pair(j)~=work.pair then return {status='superseded'} end
      local valid,why=pcall(function()authorized(j);for _,ref in ipairs(work.refs)do source(ref) end end)
      if not valid then j.status='invalidated';j.error=tostring(why);save(j);return {status=j.status} end
      if overrun or result.error=='mining_worker_failed' or result.error=='mining_time_limit' then
       j.status='budget_exhausted';j.error=result.error;save(j);return {status=j.status}
      end
      local p={id=work.pair,error=result.error,sources=work.refs}
      if result.candidate then
       local c=result.candidate
       -- One candidate per scope, generated source and execution contract; pair
       -- evidence is retained independently in mining_pairs/job snapshots.
       local cid=hash(canonical({VERSION,j.scope,c.source_hash,result.contract}))
       local stored={id=cid,source_hash=c.source_hash,candidate=c,contract=result.contract,sources=work.refs,activation_eligible=false}
       run('INSERT OR IGNORE INTO mining_candidates VALUES(?,?,?)',{cid,j.scope,encode(stored)})
       for _,ref in ipairs(work.refs)do run('INSERT OR IGNORE INTO retention_lineage(id,run_id) VALUES(?,?)',{cid,ref.id}) end
       p.candidate_id=cid
      end
      run('INSERT OR IGNORE INTO mining_pairs VALUES(?,?)',{p.id,encode(p)})
      advance(j,p)
      return {status=j.status,job_id=j.id,cursor=j.cursor}
     end)
     live=nil
     if timer then uv.timer_stop(timer);uv.close(timer);timer=nil end
     return response
    end
    if foreground then return {status='deferred'} end
    if not id then
     local selected=rows("SELECT id FROM mining_jobs WHERE json_extract(body,'$.status')='queued' AND (json_extract(body,'$.mode')='directed' OR ?=1) ORDER BY json_extract(body,'$.mode') DESC,id LIMIT 1",{o.background_enabled and 1 or 0})[1]
     id=selected and selected.id
    end
    if not id then return {status='idle'} end
    local j=get(id);authorized(j)
    if j.status~='queued' then return {status=j.status} end
    if j.mode=='background' and not o.background_enabled then return {status='disabled'} end
    local wall_ms=math.min(j.budget.wall_ms,(budget or {}).wall_ms or j.budget.wall_ms)
    assert(integer(wall_ms,1,1000),'mining_invalid_budget')
    if j.attempts>=j.budget.ticks then j.status='budget_exhausted';save(j);return {status=j.status} end
    local key,a,b=pair(j)
    local selected_cursor,selected_generation=j.cursor,j.generation or 0
    local traces={source(a),source(b)}
    local cached=rows('SELECT body FROM mining_pairs WHERE id=?',{key})[1]
    if cached then return transaction(db,function()
     j=get(id);if j.status~='queued' then return {status=j.status} end
     if j.cursor~=selected_cursor or (j.generation or 0)~=selected_generation or pair(j)~=key then return {status='superseded'} end
     authorized(j);source(a);source(b)
     advance(j,json.decode(cached.body));return {status=j.status,job_id=id,cursor=j.cursor}
    end)end
    local owner=tostring(sys.pid())..'/'..evidence.id('mining-claim')
    local claim=transaction(db,function()
     local slot=rows('SELECT owner,expires FROM mining_slot WHERE id=1')[1]
     if slot.owner~='' and owner_alive(slot.owner) then return false end
     j=get(id);if j.status~='queued' then return false end
     if j.cursor~=selected_cursor or (j.generation or 0)~=selected_generation or pair(j)~=key then return 'superseded' end
     run('UPDATE mining_slot SET owner=?,expires=? WHERE id=1',{owner,os.time()+30})
     j.attempts=j.attempts+1;save(j);return true
    end)
    if claim=='superseded' then return {status='superseded',job_id=id} end
    if not claim then return {status='busy'} end
    -- Install recoverable ownership before any fallible accounting or spawn.
    pending={owner=owner,job=id,response={status='admission_failed',job_id=id}}
    arm_timer()
    -- Conservative CPU reservation survives interruption; no model/capability
    -- invocation is issued by analysis, preserving foreground effect quotas.
    local receipt,why=o.ledger:reserve(authorized(j),owner,{analysis_ms=wall_ms,tokens=0,cost=0})
    if not receipt then
     pending.response={status='quota_denied',error=why,job_id=id}
     return release_pending()
    end
    pending.reserved=true
    local started=uv.hrtime()
    local spawned,h=pcall(worker.spawn,WORKER,{arg=encode({traces=traces}),label='mining',kind='analysis'})
    if not spawned then
     pending.failure='mining_worker_unavailable'
     pending.response={status='failed',error=pending.failure,job_id=id}
     return release_pending()
    end
    live={handle=h,job=id,cursor=selected_cursor,generation=j.generation or 0,pair=key,owner=owner,refs={a,b},deadline=started+wall_ms*1000000,started=started,wall_ms=wall_ms}
    pending=nil
    arm_timer()
    return {status='running',job_id=id}
   end)
  end
  return engine
 end)
end
local configured
function M.configure(o) local e,why=M.open(o);if e then configured=e end;return e,why end
for _,name in ipairs({'start','status','cancel','resume','tick'})do M[name]=function(...)assert(configured,'mining_not_configured');return configured[name](configured,...)end end
return M
