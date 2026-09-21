-- Durable observations, separate from authorization, bus delivery and resumable state.
local M = {}
local json,uv=require('json'),require('uv')
local config={enabled=true,secrets={},inline_bytes=16384,max_bytes=1048576}
local initialized=setmetatable({}, {__mode='k'})
local failures=0
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
]]
local function checked(v,e) if v==nil or v==false then error(e or 'evidence database failure',0) end;return v end
function M.id(prefix)
  local bytes=assert(uv.random(16))
  return (prefix or 'evidence')..':'..bytes:gsub('.',function(c)return string.format('%02x',c:byte())end)
end
function M.now() return (config.monotonic or uv.hrtime)() end
local function connection()
  local db=config.db or (bog and bog.db)
  assert(db,'evidence database unavailable')
  if not initialized[db] then checked(db:exec(schema));initialized[db]=true end
  return db
end
function M.configure(options)
  options=options or {}
  for k,v in pairs(options) do
    assert(k=='db' or k=='enabled' or k=='secrets' or k=='inline_bytes' or k=='max_bytes' or k=='wall' or k=='monotonic','unknown evidence option')
    if k=='enabled' then assert(type(v)=='boolean') end
    if k=='secrets' then assert(type(v)=='table');credential_list(v) end
    if k=='inline_bytes' or k=='max_bytes' then assert(type(v)=='number' and v>=1 and v<=1048576 and v%1==0) end
    if k=='wall' or k=='monotonic' then assert(type(v)=='function') end
  end
  for k,v in pairs(options) do config[k]=k=="secrets" and credential_list(v) or v end
  return true
end
function M.status() return {enabled=config.enabled,failures=failures,redaction_blocked=redaction_blocked,learned_secrets=#learned,learned_bytes=learned_bytes,coverage=(failures>0 or redaction_blocked) and 'incomplete' or (config.enabled and 'observations_only' or 'disabled')} end
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

local function failed()
  failures=failures+1
  -- Never repeat a raw DB/serialization error containing payload bytes.
  io.stderr:write('evidence: capture failed; coverage incomplete\n')
  return nil,'evidence_capture_failed'
end
function M.append(event)
  if not config.enabled then return nil,'evidence_disabled' end
  local ok,result=pcall(function()
    local db=connection()
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
      if artifact then checked(db:run('INSERT INTO evidence_artifacts(id,body) VALUES(?,?)',{artifact.id,artifact.body})) end
      checked(db:run('INSERT INTO evidence_events(event_id,run_id,body) VALUES(?,?,?)',{e.event_id,tostring(e.run_id),body}))
      checked(db:exec('COMMIT'))
    end)
    if not committed then db:exec('ROLLBACK');error(why,0) end
    return e.event_id
  end)
  if not ok then return failed() end
  return result
end
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
