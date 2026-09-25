-- Durable deterministic source replay; never a Lua stack or an authority snapshot.
local M={}
local evidence,json=require('evidence'),require('json')
local config={}
local initialized=setmetatable({}, {__mode='k'})
local function fail(code) error({code=code,message=code,retryable=false},0) end
local function checked(v) if v==nil or v==false then fail('runstore_unavailable') end;return v end
local function connection()
  local db=config.db or (bog and bog.db)
  if not db then fail('runstore_unavailable') end
  if not initialized[db] then
    checked(db:exec([[
CREATE TABLE IF NOT EXISTS durable_runs (id TEXT PRIMARY KEY, body TEXT NOT NULL, status TEXT NOT NULL, owner TEXT NOT NULL, attempts INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS durable_steps (run_id TEXT NOT NULL, seq INTEGER NOT NULL, operation_id TEXT UNIQUE NOT NULL, request TEXT NOT NULL, outcome TEXT, invocation_id TEXT, PRIMARY KEY(run_id,seq));
CREATE TABLE IF NOT EXISTS durable_cache (key TEXT PRIMARY KEY, expires REAL NOT NULL, body TEXT NOT NULL);
]]));require('evidence_retention').ensure(db);initialized[db]=true
  end
  return db
end
function M.configure(options) config.db=options and options.db;return true end
-- Tagged canonical encoding preserves nil, integer precision and numeric keys.
-- Aliases become independent value copies; cycles/metatables/markers are refused.
local function encode(value)
  local seen,count={},0
  local function visit(v,depth)
    count=count+1;if count>20000 or depth>32 then fail('checkpoint_unavailable') end
    local t=type(v)
    if t=='nil' then return {'nil'} end
    if t=='boolean' or t=='string' then return {t,v} end
    if t=='number' and v==v and math.abs(v)<math.huge then
      return {math.type(v),math.type(v)=='integer' and string.format('%d',v) or string.format('%.17g',v)}
    end
    if t~='table' or getmetatable(v) or seen[v] or v.evidence_marker then fail('checkpoint_unavailable') end
    seen[v]=true
    local entries={}
    for k,x in pairs(v) do
      if type(k)~='string' and type(k)~='number' and type(k)~='boolean' then fail('checkpoint_unavailable') end
      entries[#entries+1]={visit(k,depth+1),visit(x,depth+1)}
    end
    table.sort(entries,function(a,b)return json.encode(a[1])<json.encode(b[1])end)
    seen[v]=nil
    return {'table',entries}
  end
  local body=json.encode(visit(value,0));if #body>1048576 then fail('checkpoint_unavailable') end;return body
end
local function decode(body)
  local function visit(v)
    if v[1]=='nil' then return nil end
    if v[1]=='integer' or v[1]=='float' then return assert(tonumber(v[2])) end
    if v[1]=='table' then local out={};for _,pair in ipairs(v[2]) do out[visit(pair[1])]=visit(pair[2]) end;return out end
    if v[1]=='boolean' or v[1]=='string' then return v[2] end
    fail('checkpoint_unavailable')
  end
  return visit(assert(json.decode(body)))
end
function M.snapshot(value)
  if not evidence.status().enabled or evidence.status().redaction_blocked then fail('checkpoint_unavailable') end
  local body=encode(value)
  local ok,clean=pcall(evidence.redact,value)
  if not ok or encode(clean)~=body then fail('checkpoint_unavailable') end
  return decode(body),body
end
function M.runtime()
  return {_VERSION,1,string.packsize('j'),string.packsize('n'),string.byte(string.pack('I2',1)),os.setlocale(nil)}
end
function M.identity(d)
  return {id=d.id,version=d.version,revision=d.revision,provider_revision=d.provider_revision,
    source_revision=d.source_revision,effect=d.effect,target=d.target}
end
function M.open_run(id,package,authority,resume)
  local db=connection()
  require('evidence_retention').claim_run(db,id,package.scope)
  local _,body=M.snapshot(package)
  local owner=evidence.id('owner')
  if not resume then
    checked(connection():run('INSERT INTO durable_runs(id,body,status,owner,attempts) VALUES(?,?,?,?,1)',{id,body,'running',owner}))
  else
    checked(connection():run('UPDATE durable_runs SET owner=?,attempts=attempts+1 WHERE id=? AND status NOT IN (?,?) AND attempts<8',{owner,id,'succeeded','cancelled'}))
  end
  local rows=checked(connection():query('SELECT seq,operation_id,request,outcome FROM durable_steps WHERE run_id=? ORDER BY seq',{id}))
  local session={id=id,cursor=0,rows=rows,authority=authority}
  function session:check()
    if self.fault then error(self.fault,0) end
    require('evidence_retention').assert_run(connection(),id)
    local row=checked(connection():query('SELECT owner FROM durable_runs WHERE id=?',{id}))[1]
    if not row or row.owner~=owner then fail('run_ownership_lost') end
  end
  session:check()
  function session:entry(kind,input)
    self:check()
    local _,request=M.snapshot({kind=kind,input=input})
    self.cursor=self.cursor+1
    local row=self.rows[self.cursor]
    if row then
      if row.seq~=self.cursor or row.request~=request then fail('replay_diverged') end
      return row,true
    end
    local record={seq=self.cursor,operation_id=evidence.id('operation'),request=request}
    -- Unique sequence claim is committed before dispatch. Competing reconstructors
    -- can replay but cannot both claim a new effect at the same frontier.
    checked(connection():run('INSERT INTO durable_steps(run_id,seq,operation_id,request) SELECT ?,?,?,? WHERE EXISTS (SELECT 1 FROM durable_runs WHERE id=? AND owner=?)',
      {id,record.seq,record.operation_id,request,id,owner}))
    local claimed=checked(connection():query('SELECT operation_id FROM durable_steps WHERE run_id=? AND seq=?',{id,record.seq}))[1]
    if not claimed or claimed.operation_id~=record.operation_id then fail('run_ownership_lost') end
    self.rows[self.cursor]=record
    return record,false
  end
  function session:complete(row,value)
    self:check()
    local copied,body=M.snapshot(value)
    if row.outcome and row.outcome~=body then fail('replay_diverged') end
    if not row.outcome then
      checked(connection():run('UPDATE durable_steps SET outcome=? WHERE run_id=? AND seq=? AND outcome IS NULL AND EXISTS (SELECT 1 FROM durable_runs WHERE id=? AND owner=?)',{body,id,row.seq,id,owner}))
      local stored=checked(connection():query('SELECT outcome FROM durable_steps WHERE run_id=? AND seq=?',{id,row.seq}))[1]
      if not stored or stored.outcome~=body then fail('replay_diverged') end
      row.outcome=body
    end
    return copied
  end
  function session:boundary(kind,input)
    local row=self:entry(kind,input);return self:complete(row,true)
  end
  function session:call(cap,version,args,step)
    self.last_reused=false
    local descriptor=assert(require('capability').resolve(cap,version))
    local row,old=self:entry('call',{capability=M.identity(descriptor),args=args,step=step})
    local outcome
    if old then
      if row.outcome then
        self.last_reused=true
        outcome=decode(row.outcome)
        if outcome.status~='succeeded' then fail('replay_outcome_unavailable') end
        local admitted=require('capability').reuse(self.authority,cap,version,args,outcome,'resume')
        if admitted.status~='succeeded' then fail(admitted.error and admitted.error.code or 'replay_denied') end
        -- Replay the exact original value/receipt, not a newly allocated receipt.
        return M.snapshot(outcome)
      end
      outcome=M.reconcile(row.operation_id,{authority=self.authority,guard=function()self:check()end})
      if not outcome or outcome.status~='succeeded' then fail('reconciliation_uncertain') end
      return M.snapshot(outcome)
    end
    outcome=require('capability').call(self.authority,cap,version,args,{operation_id=row.operation_id,guard=function(execution)
      self:check()
      checked(connection():run('UPDATE durable_steps SET invocation_id=? WHERE operation_id=?',{execution.invocation_id,row.operation_id}))
    end})
    if outcome.status=='uncertain' then fail('reconciliation_uncertain') end
    return self:complete(row,outcome)
  end
  function session:resolve(input,fn)
    local row,old=self:entry('resolve',input)
    if old then if not row.outcome then fail('replay_result_missing') end;return table.unpack(decode(row.outcome),1,decode(row.outcome).n) end
    local result=self:complete(row,table.pack(fn()))
    return table.unpack(result,1,result.n)
  end
  function session:finish(status)
    local current=checked(connection():query('SELECT owner FROM durable_runs WHERE id=?',{id}))[1]
    if not current or current.owner~=owner then fail('run_ownership_lost') end
    if status=='succeeded' and self.cursor<#self.rows then fail('replay_diverged') end
    checked(connection():run('UPDATE durable_runs SET status=? WHERE id=? AND owner=?',{status,id,owner}))
  end
  for name,fn in pairs(session) do
    if type(fn)=='function' then
      session[name]=function(self,...)
        local result=table.pack(pcall(fn,self,...))
        if not result[1] then
          self.fault=type(result[2])=='table' and result[2] or {code='runstore_unavailable'}
          if self.on_error then self.on_error(self.fault) end
          error(self.fault,0)
        end
        return table.unpack(result,2,result.n)
      end
    end
  end
  return session
end
function M.reconcile(operation_id,options)
  if not options or not options.authority then return nil,{code='current_authority_required'} end
  local rows=checked(connection():query('SELECT run_id,seq,request,outcome,invocation_id FROM durable_steps WHERE operation_id=?',{operation_id}))
  local row=rows[1];if not row then return nil,{code='operation_not_found'} end
  require('evidence_retention').assert_run(connection(),row.run_id)
  local request=M.snapshot(decode(row.request))
  if request.kind~='call' then return nil,{code='reconciliation_unavailable'} end
  local package_row=checked(connection():query('SELECT body FROM durable_runs WHERE id=?',{row.run_id}))[1]
  local package=M.snapshot(decode(package_row.body))
  local authority=require('invoke').restrict_durable(options.authority,package.restrictions)
  local input=request.input;local d=require('capability').resolve(input.capability.id,input.capability.version)
  if not d or encode(M.identity(d))~=encode(input.capability) then return nil,{code='dependency_changed'} end
  if row.outcome then
    local outcome=decode(row.outcome)
    local admitted=require('capability').reuse(authority,d.id,d.version,input.args,outcome,'reconcile_recorded')
    if admitted.status~='succeeded' then return nil,admitted.error end
    return M.snapshot(outcome)
  end
  local outcome=require('capability').reconcile(authority,d.id,d.version,input.args,operation_id,options.guard)
  if outcome.status~='succeeded' then return nil,{code='reconciliation_uncertain',outcome=outcome} end
  outcome.receipt.original_invocation_id=row.invocation_id
  local ledgers={}
  for _,restriction in ipairs(package.restrictions) do if restriction.ledger then ledgers[restriction.ledger.id]=restriction.ledger end end
  if next(ledgers) then outcome.receipt.accounting_pending={invocation_id=row.invocation_id,reservation_id=operation_id,ledgers=ledgers,settlement='not_attempted'} end
  local copied,body=M.snapshot(outcome)
  checked(connection():run('UPDATE durable_steps SET outcome=? WHERE operation_id=? AND outcome IS NULL',{body,operation_id}))
  local saved=checked(connection():query('SELECT outcome FROM durable_steps WHERE operation_id=?',{operation_id}))[1]
  if saved.outcome~=body then fail('reconciliation_conflict') end
  return copied
end
function M.resume(id,options)
  options=options or {}
  if not options.authority then return nil,{code='current_authority_required'} end
  local ok,result,why=pcall(function()
    require('evidence_retention').assert_run(connection(),id)
    local row=checked(connection():query('SELECT body,status,attempts FROM durable_runs WHERE id=?',{id}))[1]
    if not row then return nil,{code='workflow_non_resumable'} end
    if row.attempts>=8 then return nil,{code='resume_limit'} end
    if row.status=='succeeded' or row.status=='cancelled' then return nil,{code='run_terminal'} end
    local package=M.snapshot(decode(row.body))
    if options.expected_root and (package.root~=options.expected_root or package.version~=options.expected_version) then return nil,{code='recovery_identity_mismatch'} end
    if encode(package.runtime)~=encode(M.runtime()) then return nil,{code='runtime_changed'} end
    local workflow=require('workflow')
    local function executable_identity(d)
      return {id=d.id,version=d.version,source_hash=d.source_hash,durable=d.durable,
        capabilities=d.capabilities or {},workflows=d.workflows or {}}
    end
    -- Verify every exact binding before registering any absent definitions. An
    -- unchanged aggregate dependency set does not prove unchanged source edges.
    for _,d in ipairs(package.sources) do
      local current=workflow.resolve(d.id,d.version)
      if current and encode(executable_identity(current))~=encode(executable_identity(d)) then
        return nil,{code='dependency_changed'}
      end
    end
    for _,d in ipairs(package.sources) do
      if not workflow.resolve(d.id,d.version) then assert(workflow.register(d)) end
    end
    local authority=require('invoke').restrict_durable(options.authority,package.restrictions)
    return workflow.start(package.root,{version=package.version,scope=package.scope,context=package.context,source_revisions=package.source_revisions,
      authority=authority,instructions=math.min(options.instructions or package.instructions,package.instructions),
      learning=options.learning,admit=options.admit,on_terminal=options.on_terminal,
      _durable_resume={id=id,package=package}})
  end)
  if not ok then return nil,type(result)=='table' and result or {code='recovery_failed',message=tostring(result)} end
  return result,why
end
-- Lua string methods reach the process string metatable even when env.string is
-- copied. Refuse raw identity/bytecode formatting originating in source; the
-- checked env.string.format wrapper remains available for ordinary formatting.
function M.source_hook(previous,mask,deny)
  local tools=require("tools")
  return function(event,line)
    local callee=tools.current_hook_target()
    if (event=='call' or event=='tail call') and
        (not callee or callee==string.format or callee==string.dump) then
      local target=false
      local level=2
      while true do
        local info=debug.getinfo(level,'fS')
        if not info then break end
        if info.func==string.format or info.func==string.dump then target=true
        elseif target and info.what~='C' then
          if string.sub(info.source,1,10)=='@workflow:' then deny() end
          break
        end
        if string.sub(info.source,1,10)=='@workflow:' then break end
        level=level+1
      end
    end
    local code=event=='line' and 'l' or event=='return' and 'r' or 'c'
    if previous and (event=='count' or string.find(mask,code,1,true)) then previous(event,line) end
  end
end
-- Deterministic subset retains ordinary Lua computation and stable iteration.
function M.environment(env,deny)
  env.os={};env.coroutine={};env.gold={};env.json={};env.setmetatable=deny
  for _,name in ipairs({'time','clock','date','difftime','getenv','execute'}) do env.os[name]=deny end
  for _,name in ipairs({'create','resume','wrap','yield','running','status','close','isyieldable'}) do env.coroutine[name]=deny end
  env.math.random=deny;env.math.randomseed=deny;env.string.dump=deny
  env.tostring=function(v) if type(v)=='table' or type(v)=='function' or type(v)=='thread' or type(v)=='userdata' then return deny() end;return tostring(v) end
  env.string.format=function(fmt,...)
    if fmt:find('%%[^%%]-p') then return deny() end
    local args=table.pack(...)
    for i=1,args.n do
      local v=args[i]
      if type(v)=='table' or type(v)=='function' or type(v)=='thread' or type(v)=='userdata' then return deny() end
    end
    return string.format(fmt,...)
  end
  local function keys(t)
    if getmetatable(t) then return deny() end
    local out={};for k in pairs(t) do
      if type(k)~='string' and type(k)~='number' then return deny() end
      out[#out+1]=k
    end
    table.sort(out,function(a,b)if type(a)~=type(b) then return type(a)<type(b) end;return a<b end)
    return out
  end
  env.pairs=function(t) local order=keys(t);local i=0;return function()i=i+1;local k=order[i];if k~=nil then return k,t[k] end end end
  env.next=function(t,k) local order=keys(t);if k==nil then return order[1],t[order[1]] end;for i,key in ipairs(order) do if key==k then local n=order[i+1];return n,n and t[n] end end;return deny() end
  return env
end
local function cache_key(descriptor,args,dependencies,freshness)
  local d=require('capability').resolve(descriptor.id,descriptor.version)
  if not d or d.cache~='result' or (d.effect~='pure' and d.effect~='read') then return nil,'cache_ineligible' end
  if type(d.revision)~='string' or d.revision=='' or type(d.provider_revision)~='string' or d.provider_revision=='' or type(d.source_revision)~='string' or d.source_revision=='' then return nil,'cache_revision_required' end
  if encode(M.identity(d))~=encode(M.identity(descriptor)) then return nil,'cache_revision_changed' end
  if type(freshness)~='table' or type(freshness.ttl)~='number' or freshness.ttl~=freshness.ttl or freshness.ttl<=0 or freshness.ttl>31536000 or type(freshness.revision)~='string' then return nil,'cache_freshness_required' end
  local _,body=M.snapshot({descriptor=M.identity(d),args=args,dependencies=dependencies,freshness=freshness})
  return require('workflow').hash(body),d
end
M.cache={}
local function owned_cache(key,options)
  local current=require('invoke').correlation()
  local explicit=options and options.scope
  assert(not current.scope or not explicit or current.scope==explicit,'retention_scope_mismatch')
  local scope=current.scope or explicit or require('project').current()
  local db=connection();require('evidence_retention').assert_scope(db,scope)
  return require('workflow').hash(encode({scope=scope,key=key})),scope,db
end
function M.cache.store(descriptor,args,dependencies,freshness,outcome,options)
  local key,why=cache_key(descriptor,args,dependencies,freshness)
  if not key then return nil,why end
  if outcome.status~='succeeded' or not outcome.receipt or not outcome.receipt.dispatched or outcome.receipt.id~=descriptor.id or outcome.receipt.version~=descriptor.version then return nil,'cache_outcome_invalid' end
  local _,body=M.snapshot(outcome)
  local scope,db;key,scope,db=owned_cache(key,options)
  checked(db:run('INSERT OR IGNORE INTO retention_cache(key,scope) VALUES(?,?)',{key,scope}))
  checked(db:run('INSERT OR REPLACE INTO durable_cache(key,expires,body) VALUES(?,?,?)',{key,os.time()+freshness.ttl,body}))
  return true
end
function M.cache.lookup(descriptor,args,dependencies,freshness,options)
  if not options or not options.authority then return nil,'current_authority_required' end
  local key,d=cache_key(descriptor,args,dependencies,freshness)
  if not key then return nil,d end
  key=owned_cache(key,options)
  local row=checked(connection():query('SELECT expires,body FROM durable_cache WHERE key=?',{key}))[1]
  if not row or row.expires<=os.time() then return nil,'cache_miss' end
  local saved=M.snapshot(decode(row.body))
  local result=require('capability').reuse(options.authority,d.id,d.version,args,saved,'cache')
  if result.status~='succeeded' then return nil,result.error end
  return result
end
return M
