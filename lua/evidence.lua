-- Durable observations, separate from authorization, bus delivery and resumable state.
local M = {}
local json,uv=require('json'),require('uv')
local config={enabled=true,secrets={},inline_bytes=16384,max_bytes=1048576,failure_policy='stop'}
local initialized=setmetatable({}, {__mode='k'})
local failures=0
local GAP_COUNT,GAP_BYTES,GAP_RETRIES=256,65536,16
local GAP_STORES,GAP_TOTAL_COUNT,GAP_TOTAL_BYTES=8,512,131072
local pending_gaps={} -- Strong ownership until persisted, tombstoned, or conservatively aggregated.
local gap_cursor,capture_blocked,registry_overflow=nil,false,false
local attach_store
local SECRET_COUNT,SECRET_BYTES,SECRET_LENGTH,WORK_LIMIT=256,65536,8192,16777216
local learned,learned_set,learned_bytes={}, {},0
local redaction_blocked=false
local function unsafe_redaction()
  redaction_blocked=true
  error('evidence_redaction_capacity',0)
end
local function credential_list(values)
  local out,set,bytes={}, {},0
  for _,value in ipairs(values) do
    assert(type(value)=='string' and #value>0,'invalid secret')
    if #value>SECRET_LENGTH then unsafe_redaction() end
    if not set[value] then
      bytes=bytes+#value
      if #out>=SECRET_COUNT or bytes>SECRET_BYTES then unsafe_redaction() end
      out[#out+1]=value;set[value]=true
    end
  end
  return out,set,bytes
end
local schema=[[
CREATE TABLE IF NOT EXISTS evidence_events (seq INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE NOT NULL,run_id TEXT NOT NULL,body TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS evidence_run ON evidence_events(run_id,seq);
CREATE TABLE IF NOT EXISTS evidence_artifacts (id TEXT PRIMARY KEY,body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS evidence_gaps (run_id TEXT PRIMARY KEY,reason TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS evidence_capture_state (id INTEGER PRIMARY KEY CHECK(id=1),reason TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS evidence_store_identity (id INTEGER PRIMARY KEY CHECK(id=1),identity TEXT NOT NULL);
]]
local function checked(v,e) if v==nil or v==false then error(e or 'evidence database failure',0) end;return v end
function M.id(prefix)
  local bytes=assert(uv.random(16))
  return (prefix or 'evidence')..':'..bytes:gsub('.',function(c)return string.format('%02x',c:byte())end)
end
function M.now() return (config.monotonic or uv.hrtime)() end
local function store_identity(db)
  local row=checked(db:query('SELECT identity FROM evidence_store_identity WHERE id=1'))[1]
  assert(row and type(row.identity)=='string' and #row.identity==38 and row.identity:match('^store:%x+$'),'evidence_store_identity_unavailable')
  return row.identity
end
local function connection()
  local db=config.db or (bog and bog.db)
  assert(db,'evidence database unavailable')
  if not initialized[db] then
    checked(db:exec(schema));require('evidence_retention').ensure(db)
    -- The unique singleton plus INSERT OR IGNORE atomically elects one identity
    -- even when independent connections initialize the same store concurrently.
    checked(db:run('INSERT OR IGNORE INTO evidence_store_identity(id,identity) VALUES(1,?)',{M.id('store')}))
    initialized[db]=true
  end
  local identity=store_identity(db)
  if attach_store then attach_store(db,identity) end
  if registry_overflow then
    checked(db:run("INSERT OR IGNORE INTO evidence_capture_state(id,reason) VALUES(1,'pending_gap_registry_capacity')"))
  end
  if #checked(db:query('SELECT id FROM evidence_capture_state WHERE id=1'))>0 then capture_blocked=true end
  return db,identity
end
function M.configure(options)
  options=options or {}
  for k,v in pairs(options) do
    assert(k=='db' or k=='enabled' or k=='secrets' or k=='inline_bytes' or k=='max_bytes' or k=='wall' or k=='monotonic' or k=='failure_policy','unknown evidence option')
    if k=='failure_policy' then assert(v=='stop' or v=='degraded') end
    if k=='enabled' then assert(type(v)=='boolean') end
    if k=='secrets' then assert(type(v)=='table');credential_list(v) end
    if k=='inline_bytes' or k=='max_bytes' then assert(type(v)=='number' and v>=1 and v<=1048576 and v%1==0) end
    if k=='wall' or k=='monotonic' then assert(type(v)=='function') end
  end
  for k,v in pairs(options) do config[k]=k=="secrets" and credential_list(v) or v end
  if options.db~=nil then pcall(connection) end -- Verified wrapper/reopen rebinding, best effort on outage.
  return true
end
function M.status()
  local count,bytes,markers,stores=0,0,0,0
  for _,queue in pairs(pending_gaps) do stores=stores+1;count=count+#queue.order;bytes=bytes+queue.bytes;if queue.marker_pending then markers=markers+1 end end
  return {enabled=config.enabled,failure_policy=config.failure_policy,failures=failures,redaction_blocked=redaction_blocked,
    capture_blocked=capture_blocked,gap_registry_overflow=registry_overflow,pending_gap_stores=stores,gap_store_limit=GAP_STORES,gap_total_limit=GAP_TOTAL_COUNT,gap_total_byte_limit=GAP_TOTAL_BYTES,pending_gaps=count,pending_gap_bytes=bytes,pending_gap_markers=markers,gap_queue_limit=GAP_COUNT,gap_byte_limit=GAP_BYTES,gap_retry_limit=GAP_RETRIES,
    learned_secrets=#learned,learned_bytes=learned_bytes,coverage=(failures>0 or redaction_blocked or capture_blocked) and 'incomplete' or (config.enabled and 'observations_only' or 'disabled')}
end
local function secret_key(k)
  return type(k)=='string' and (k:lower():find('password',1,true) or k:lower():find('secret',1,true)
    or k:lower()=='token' or k:lower():match('_token$') or k:lower():find('api_key',1,true) or k:lower()=='authorization' or k:lower()=='credential')
end
function M.redact(value)
  if redaction_blocked then unsafe_redaction() end
  local secrets,known,secret_bytes=credential_list(config.secrets)
  local work=0
  local function charge(amount)
    work=work+amount;if work>WORK_LIMIT then unsafe_redaction() end
  end
  local function add(secret,remember)
    if #secret==0 then return end
    if #secret>SECRET_LENGTH then unsafe_redaction() end
    if not known[secret] then
      if #secrets>=SECRET_COUNT or secret_bytes+#secret>SECRET_BYTES then unsafe_redaction() end
      secrets[#secrets+1]=secret;known[secret]=true;secret_bytes=secret_bytes+#secret
    end
    if remember and not learned_set[secret] then
      if #learned>=SECRET_COUNT or learned_bytes+#secret>SECRET_BYTES then unsafe_redaction() end
      learned[#learned+1]=secret;learned_set[secret]=true;learned_bytes=learned_bytes+#secret
    end
  end
  for _,secret in ipairs(learned) do add(secret,false) end
  -- A sensitive visit must upgrade an earlier public alias. Each table is
  -- visited at most once per sensitivity state, including cyclic graphs.
  local scanned,count={},0
  local function collect(v,sensitive,depth)
    count=count+1
    if count>20000 or depth>32 then unsafe_redaction() end
    if type(v)=='string' and sensitive then add(v,true)
    elseif type(v)=='table' and not getmetatable(v) then
      local state=scanned[v]
      if state==true or state==false and not sensitive then return end
      scanned[v]=sensitive==true
      for k,x in next,v do
        if type(k)=='string' then charge(#k);if sensitive then add(k,true) end end
        collect(x,sensitive or not not secret_key(k),depth+1)
      end
    end
  end
  collect(value,false,0)
  local seen,n,bytes={},0,0
  local function clean(v,depth)
    n=n+1
    if n>20000 or depth>32 then return {evidence_marker='truncated',reason='structure_limit'} end
    local t=type(v)
    if t=='string' then
      bytes=bytes+#v
      if bytes>config.max_bytes then return {evidence_marker='truncated',reason='byte_limit',bytes=#v} end
      local original=v
      -- Bound even a worst-case naive literal search by input * needle bytes.
      -- Match against original bytes so one replacement cannot hide a later secret.
      local spans={}
      for _,secret in ipairs(secrets) do
        charge((#original+1)*(#secret+1))
        local from=1
        while true do
          local first,last=original:find(secret,from,true)
          if not first then break end
          if #spans>=20000 then unsafe_redaction() end
          spans[#spans+1]={first,last};charge(1);from=last+1
        end
      end
      table.sort(spans,function(a,b)return a[1]<b[1] end)
      local pieces,at={},1
      for _,span in ipairs(spans) do
        if span[2]>=at then
          if span[1]>=at then pieces[#pieces+1]=original:sub(at,span[1]-1);pieces[#pieces+1]='[REDACTED]' end
          at=span[2]+1
        end
      end
      pieces[#pieces+1]=original:sub(at);v=table.concat(pieces)
      return v:gsub('([Bb]earer%s+)[%w%._~+/%-=]+','%1[REDACTED]')
    end
    if t=='nil' or t=='boolean' then return v end
    if t=='number' then return v==v and math.abs(v)<math.huge and v or {evidence_marker='unavailable',reason='nonfinite'} end
    if t~='table' or getmetatable(v) then return {evidence_marker='unavailable',reason='opaque_'..t} end
    if seen[v] then return {evidence_marker='unavailable',reason='cycle'} end
    seen[v]=true;local out,omissions,encoded_keys={},{},{}
    local function omitted(reason) omissions[reason]=(omissions[reason] or 0)+1 end
    for k,x in next,v do
      if n>20000 then omitted('structure_limit');break end
      if type(k)=='string' or type(k)=='number' and k==k and math.abs(k)<math.huge then
        local safe=type(k)=='string' and clean(k,depth+1) or k
        if type(safe)~='string' and type(safe)~='number' then omitted('key_truncated')
        elseif encoded_keys[tostring(safe)] then omitted('key_collision')
        else
          encoded_keys[tostring(safe)]=true
          out[safe]=secret_key(k) and {evidence_marker='redacted'} or clean(x,depth+1)
        end
      else omitted('unsupported_key') end
    end
    seen[v]=nil
    if next(omissions) then return {evidence_marker='partial',reason='keys_omitted',value=out,omissions=omissions} end
    return out
  end
  return clean(value,0)
end

local function registry_size()
  local stores,count,bytes=0,0,0
  for _,q in pairs(pending_gaps) do stores=stores+1;count=count+#q.order;bytes=bytes+q.bytes end
  return stores,count,bytes
end
local function registry_refusal()
  capture_blocked=true;registry_overflow=true
  for _,q in pairs(pending_gaps) do q.marker_pending=true end
end
attach_store=function(db,identity)
  local unknown=pending_gaps[db]
  local known=pending_gaps[identity]
  if unknown then
    pending_gaps[db]=nil
    if known then
      -- Two previously unidentified handles are now proved to be the same
      -- store. Aggregate their uncertainty conservatively, without exceeding
      -- per-store queue bounds or retaining another candidate handle.
      capture_blocked=true
      known.entries={};known.order={};known.bytes=0;known.marker_pending=true
    else
      known=unknown;pending_gaps[identity]=known
    end
  end
  if known then known.db=db;known.identity=identity end
end
local function new_queue(db,identity)
  local key=identity or db
  local queue=pending_gaps[key]
  if queue then return key,queue end
  if registry_size()>=GAP_STORES then registry_refusal();return key,nil end
  queue={db=db,identity=identity,entries={},order={},bytes=0}
  pending_gaps[key]=queue
  return key,queue
end
local function discard_gap(queue,index)
  local id=table.remove(queue.order,index)
  local entry=queue.entries[id]
  queue.bytes=queue.bytes-entry.bytes;queue.entries[id]=nil
end
local function tombstoned(db,id,scope)
  if #checked(db:query('SELECT id FROM retention_session_ids WHERE CAST(id AS TEXT)=?',{id}))>0 then return true end
  local row=checked(db:query('SELECT scope FROM retention_runs WHERE run_id=?',{id}))[1]
  scope=row and row.scope or scope
  if scope and #checked(db:query('SELECT scope FROM retention_scopes WHERE scope=? AND deleted_at IS NOT NULL UNION SELECT scope FROM import_tombstones WHERE scope=?',{scope,scope}))>0 then return true end
  return false,row~=nil,row and row.scope
end
local function verify_store(db,expected)
  local identity=store_identity(db)
  assert(not expected or expected==identity,'evidence_store_identity_changed')
  return identity
end
local function persist_gap(db,id,scope,identity)
  verify_store(db,identity)
  local deleted,known=tombstoned(db,id,scope)
  if deleted then return end
  if not known then require('evidence_retention').claim_run(db,id,scope) end
  checked(db:run("INSERT OR IGNORE INTO evidence_gaps(run_id,reason) VALUES(?,'capture_incomplete')",{id}))
end
local function persist_overflow(db,identity)
  verify_store(db,identity)
  checked(db:run("INSERT OR IGNORE INTO evidence_capture_state(id,reason) VALUES(1,'pending_gap_capacity')"))
end
local function flush_gaps()
  for _=1,GAP_RETRIES do
    if gap_cursor and not pending_gaps[gap_cursor] then gap_cursor=nil end
    local key,queue=next(pending_gaps,gap_cursor)
    if not key then key,queue=next(pending_gaps) end
    if not key then return end
    gap_cursor=key
    -- Unknown handles can only be rebound after reading the persistent opaque
    -- identity; filesystem paths and payload/run IDs are never store identity.
    if not queue.identity then
      local ok,identity=pcall(store_identity,queue.db)
      if ok then attach_store(queue.db,identity);key=identity;queue=pending_gaps[key];gap_cursor=key end
    end
    if queue.marker_pending then
      if pcall(persist_overflow,queue.db,queue.identity) then queue.marker_pending=false end
    elseif #queue.order>0 then
      local id=queue.order[1];local entry=queue.entries[id]
      if pcall(persist_gap,queue.db,id,entry.scope,queue.identity) then discard_gap(queue,1)
      else table.remove(queue.order,1);queue.order[#queue.order+1]=id end
    end
    if #queue.order==0 and not queue.marker_pending then pending_gaps[key]=nil;gap_cursor=nil end
  end
end
local function record_gap(event)
  if type(event)~='table' then return end
  local id=event.run_id
  if not (type(id)=='string' and #id<=4096 or type(id)=='number' and id==id and math.abs(id)<math.huge) then return end
  local db=config.db or (bog and bog.db)
  if not db then return end
  id=tostring(id)
  local scope=event.scope
  local connected,_,identity=pcall(connection)
  if not connected then
    identity=nil
    for _,q in pairs(pending_gaps) do if q.db==db then identity=q.identity;break end end
  end
  local proven,deleted,known,stored_scope=pcall(tombstoned,db,id,scope)
  if proven and deleted then return end
  if proven and known then scope=stored_scope
  else
    local safe=pcall(function()
      assert(M.redact(id)==id)
      if scope~=nil then assert(type(scope)=='string' and #scope>0 and #scope<=1024 and M.redact(scope)==scope) end
    end)
    if not safe then return end
  end
  local key=identity or db
  local queue=pending_gaps[key]
  if pcall(persist_gap,db,id,scope,identity) then
    if queue and queue.entries[id] then
      for i,queued_id in ipairs(queue.order) do if queued_id==id then discard_gap(queue,i);break end end
    end
    return
  end
  key,queue=new_queue(db,identity)
  if not queue then pcall(persist_overflow,db,identity);return end
  if capture_blocked then
    queue.marker_pending=true
    if pcall(persist_overflow,db,identity) then queue.marker_pending=false end
    return
  end
  if queue.entries[id] then return end
  local bytes=#id+(scope and #scope or 0)
  local _,total_count,total_bytes=registry_size()
  if total_count>=GAP_TOTAL_COUNT or total_bytes+bytes>GAP_TOTAL_BYTES then
    registry_refusal()
    if pcall(persist_overflow,db,identity) then queue.marker_pending=false end
    return
  end
  if #queue.order>=GAP_COUNT or queue.bytes+bytes>GAP_BYTES then
    capture_blocked=true;queue.marker_pending=true
    if pcall(persist_overflow,db,identity) then queue.marker_pending=false end
    return
  end
  queue.entries[id]={scope=scope,bytes=bytes};queue.order[#queue.order+1]=id;queue.bytes=queue.bytes+bytes
end
local function failed(event)
  failures=failures+1
  record_gap(event)
  -- Never repeat a raw DB/serialization error containing payload bytes.
  io.stderr:write('evidence: capture failed; coverage incomplete\n')
  return nil,'evidence_capture_failed'
end
function M.append(event)
  if not config.enabled then
    local ok=pcall(function() local db=connection();flush_gaps();assert(not capture_blocked,'evidence_capture_capacity');require('evidence_retention').claim_run(db,event.run_id,event.scope) end)
    if not ok then return failed(event) end
    record_gap(event)
    return nil,'evidence_disabled'
  end
  local ok,result=pcall(function()
    local db=connection()
    flush_gaps()
    assert(not capture_blocked,'evidence_capture_capacity')
    assert(type(event)=='table' and event.run_id~=nil and type(event.kind)=='string','invalid evidence event')
    M.redact({event.payload,event.provenance}) -- learn both before either snapshot
    local e={kind=event.kind,payload=M.redact(event.payload),provenance=M.redact(event.provenance)}
    assert(event.kind:match('^[%w_.]+$') and #event.kind<128,'invalid kind')
    local native=event.kind:match('^(invocation)%.') or event.kind:match('^(workflow)%.') or event.kind:match('^(context)%.') or event.kind:match('^(step)%.') or event.kind:match('^(observation)%.') or event.kind=='session.entry'
    assert(native or M.redact(event.kind)==event.kind,'secret kind')
    -- Structural field names and native lifecycle kinds are not user values.
    -- Correlation labels are required to be nonsecret; refuse rather than
    -- rewriting them into ambiguous identities or storing a credential.
    for _,field in ipairs({'run_id','step_id','parent_id','attempt_id','correlation_id'}) do
      local v=event[field]
      if v~=nil then
        assert((type(v)=='string' and #v<=4096 or type(v)=='number') and M.redact(v)==v,'secret or invalid correlation label')
        e[field]=v
      end
    end
    e.schema_version=1;e.event_id=M.id('event');e.origin='native' 
    e.provenance=e.provenance or {observation='direct_runtime'}
    e.timestamp=(config.wall or os.time)();e.attempt_id=e.attempt_id or '1'
    local payload=json.encode(e.payload or {})
    local artifact
    if #payload>config.max_bytes then e.payload={evidence_marker='truncated',reason='payload_byte_limit',bytes=#payload}
    elseif #payload>config.inline_bytes then
      artifact={id=M.id('artifact'),body=payload}
      e.payload={evidence_marker='artifact',id=artifact.id};e.artifact_refs={{id=artifact.id,bytes=#payload,encoding='json'}}
    end
    local body=json.encode(e)
    checked(db:exec('BEGIN IMMEDIATE'))
    local committed,why=pcall(function()
      local retention=require('evidence_retention')
      e.scope=retention.claim_run(db,e.run_id,event.scope)
      body=json.encode(e)
      if artifact then checked(db:run('INSERT INTO retention_artifacts(id,run_id) VALUES(?,?)',{artifact.id,tostring(e.run_id)})) end
      if artifact then checked(db:run('INSERT INTO evidence_artifacts(id,body) VALUES(?,?)',{artifact.id,artifact.body})) end
      checked(db:run('INSERT INTO evidence_events(event_id,run_id,body) VALUES(?,?,?)',{e.event_id,tostring(e.run_id),body}))
      checked(db:exec('COMMIT'))
    end)
    if not committed then db:exec('ROLLBACK');error(why,0) end
    return e.event_id
  end)
  if not ok then return failed(event) end
  return result
end
function M.assert_scope(scope) return require('evidence_retention').assert_scope(connection(),scope) end
function M.assert_run(run_id) return require('evidence_retention').assert_run(connection(),run_id) end
function M.scope_for_run(run_id) return require('evidence_retention').run_scope(connection(),run_id) end
function M.artifact(id)
  local rows=checked(connection():query('SELECT body FROM evidence_artifacts WHERE id=?',{id}))
  return rows[1] and json.decode(rows[1].body)
end
function M.read_run(run_id)
  local ok,result=pcall(function()
    local rows=checked(connection():query('SELECT body FROM evidence_events WHERE run_id=? ORDER BY seq',{tostring(run_id)}))
    local out,pending={},{}
    for _,row in ipairs(rows) do
      local e=json.decode(row.body);out[#out+1]=e
      if e.kind:match('%.start$') and e.correlation_id then pending[e.correlation_id]=e
      elseif e.kind:match('%.terminal$') and e.correlation_id then pending[e.correlation_id]=nil end
    end
    -- Derived coverage records are deterministic and never assert an effect failed.
    for _,e in ipairs(out) do
      if pending[e.correlation_id]==e then
        out[#out+1]={schema_version=1,event_id=e.event_id..':incomplete',run_id=e.run_id,
          step_id=e.step_id,parent_id=e.parent_id,attempt_id=e.attempt_id,correlation_id=e.correlation_id,
          kind='coverage.incomplete',origin='derived',provenance={start_event_id=e.event_id},
          timestamp=e.timestamp,payload={status='incomplete',reason='terminal_not_observed'}}
      end
    end
    return out
  end)
  if not ok then return nil,'evidence_read_failed' end
  return result
end
function M.begin(kind,correlation,payload)
  local span={};for k,v in pairs(correlation or {}) do span[k]=v end
  span.run_id=span.run_id or M.id('run');span.correlation_id=span.correlation_id or M.id(kind)
  span.kind=kind;span.started=M.now()
  local e={};for k,v in pairs(span) do if k~='started' then e[k]=v end end
  e.kind=kind..'.start';e.payload=payload
  span.event_id,span.error=M.append(e)
  return span
end
function M.finish(span,payload)
  local e={};for k,v in pairs(span) do if k~='started' and k~='error' and k~='event_id' then e[k]=v end end
  e.kind=span.kind..'.terminal';e.payload=payload or {};e.payload.duration_ns=M.now()-span.started
  e.payload.start_capture=span.event_id and 'recorded' or (span.error or 'missing')
  return M.append(e)
end
-- Storage overhead must not consume a caller's executable instruction budget or
-- let an exhausted hook interrupt a transaction. Only host-injected clocks run here.
for _,name in ipairs({'id','append','begin','finish'}) do
  local fn=M[name]
  M[name]=function(...)
    local hook,mask,count=debug.gethook()
    -- Reinstalling a count hook resets Lua's hidden remainder; charge a quantum
    -- so repeated short observations cannot starve an enclosing budget.
    if hook and count and count>0 then hook('count') end
    debug.sethook()
    local result=table.pack(pcall(fn,...))
    debug.sethook(hook,mask,count)
    if not result[1] then error(result[2],0) end
    return table.unpack(result,2,result.n)
  end
end
return M
