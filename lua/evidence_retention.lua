-- Trusted-host retention boundary. Scope names are ownership, never authority.
-- All adapters sharing a store use these durable tombstones. No daemon protocol
-- is assumed: external deletion remains pending until a trusted adapter acks it.
local M={}
local json=require('json')
local configured
local function checked(v) assert(v~=nil and v~=false,'retention_storage_failed');return v end
local function rows(db,sql,args) return checked(db:query(sql,args)) end
local function scope_name(scope)
  assert(type(scope)=='string' and #scope>0 and #scope<=1024,'retention_scope_required')
  return scope
end
local schema=[[
CREATE TABLE IF NOT EXISTS retention_scopes(scope TEXT PRIMARY KEY,expires_at REAL,deleted_at INTEGER);
CREATE TABLE IF NOT EXISTS retention_runs(run_id TEXT PRIMARY KEY,scope TEXT);
CREATE INDEX IF NOT EXISTS retention_run_scope ON retention_runs(scope);
CREATE TABLE IF NOT EXISTS retention_deleted_artifacts(id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS retention_artifacts(id TEXT PRIMARY KEY,run_id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS retention_session_ids(id INTEGER PRIMARY KEY,scope TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS retention_cache(key TEXT PRIMARY KEY,scope TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS retention_outbox(id TEXT PRIMARY KEY,scope TEXT UNIQUE NOT NULL,status TEXT NOT NULL,created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS retention_lineage(id TEXT NOT NULL,run_id TEXT NOT NULL,invalid INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(id,run_id));
CREATE TABLE IF NOT EXISTS import_tombstones(scope TEXT PRIMARY KEY);
]]
local function exists(db,name) return #rows(db,"SELECT name FROM sqlite_master WHERE type='table' AND name=?",{name})>0 end
local function trigger(db,table_name,condition)
  if not exists(db,table_name) then return end
  for _,op in ipairs({'INSERT','UPDATE'}) do
    local when=condition
    if op=='UPDATE' and (table_name=='sessions' or table_name=='memory' or table_name=='retention_runs') then when=when..' OR '..condition:gsub('NEW%.','OLD.') end
    checked(db:exec('CREATE TRIGGER IF NOT EXISTS retention_'..table_name..'_'..op..' BEFORE '..op..' ON '..table_name..
      ' WHEN '..when.." BEGIN SELECT RAISE(ABORT,'retention_scope_deleted'); END;"))
  end
end
function M.ensure(db)
  checked(db:exec(schema))
  -- Triggers are the final race boundary, including writes from suspended
  -- producers using another connection. They contain no application callbacks.
  local deleted="SELECT scope FROM retention_scopes WHERE deleted_at IS NOT NULL UNION SELECT scope FROM import_tombstones"
  trigger(db,'retention_runs','NEW.scope IN ('..deleted..')')
  local runs='SELECT run_id FROM retention_runs WHERE scope IN ('..deleted..') UNION SELECT CAST(id AS TEXT) FROM retention_session_ids'
  for _,name in ipairs({'evidence_events','evidence_gaps','durable_steps','records'}) do
    trigger(db,name,'CAST(NEW.run_id AS TEXT) IN ('..runs..')')
  end
  trigger(db,'durable_runs','NEW.id IN ('..runs..')')
  trigger(db,'journal','NEW.from_id IN (SELECT id FROM retention_session_ids) OR NEW.to_id IN (SELECT id FROM retention_session_ids)')
  -- Separate names allow both run ownership and legacy session guards.
  if exists(db,'records') then
    for _,op in ipairs({'INSERT','UPDATE'}) do checked(db:exec('CREATE TRIGGER IF NOT EXISTS retention_records_session_'..op..' BEFORE '..op..' ON records WHEN NEW.run_id IN (SELECT id FROM retention_session_ids) OR NEW.agent_id IN (SELECT id FROM retention_session_ids) BEGIN SELECT RAISE(ABORT,"retention_scope_deleted"); END;')) end
  end
  trigger(db,'retention_artifacts','NEW.run_id IN ('..runs..')')
  trigger(db,'evidence_artifacts','NEW.id IN (SELECT id FROM retention_artifacts WHERE run_id IN ('..runs..')) OR NEW.id IN (SELECT id FROM retention_deleted_artifacts)')
  trigger(db,'retention_cache','NEW.scope IN ('..deleted..')')
  trigger(db,'durable_cache','NEW.key IN (SELECT key FROM retention_cache WHERE scope IN ('..deleted..'))')
  for _,name in ipairs({'import_events','import_sources','import_refs','import_quarantine','import_checkpoints','import_aliases'}) do
    trigger(db,name,'NEW.scope IN ('..deleted..')')
  end
  for _,name in ipairs({'memory','sessions'}) do
    if exists(db,name) then
      local has_project=false
      for _,r in ipairs(rows(db,'PRAGMA table_info('..name..')')) do if r.name=='project' then has_project=true end end
      if has_project then trigger(db,name,"COALESCE(NEW.project,'global') IN ("..deleted..')'..(name=='sessions' and ' OR NEW.id IN (SELECT id FROM retention_session_ids)' or '')) end
    end
  end
  if exists(db,'sessions') then
    checked(db:exec([[CREATE TRIGGER IF NOT EXISTS retention_session_scope BEFORE UPDATE ON sessions
      WHEN EXISTS (SELECT 1 FROM retention_runs WHERE run_id=CAST(NEW.id AS TEXT) AND scope IS NOT NULL AND scope<>COALESCE(NEW.project,'global'))
      BEGIN SELECT RAISE(ABORT,'retention_scope_transfer_requires_migration'); END;]]))
  end
  return db
end
local function connection() return M.ensure(assert(configured or (bog and bog.db),'retention_database_required')) end
function M.configure(options) configured=assert(options.db);M.ensure(configured);return true end
function M.assert_scope(db,scope)
  if scope==nil then return end -- explicit legacy/unscoped compatibility lane
  scope_name(scope)
  assert(require('evidence').redact(scope)==scope,'retention_scope_sensitive')
  assert(#rows(db,'SELECT scope FROM retention_scopes WHERE scope=? AND deleted_at IS NOT NULL UNION SELECT scope FROM import_tombstones WHERE scope=?',{scope,scope})==0,'retention_scope_deleted')
end
function M.run_scope(db,id)
  local row=rows(db,'SELECT scope FROM retention_runs WHERE run_id=?',{tostring(id)})[1]
  return row and row.scope,row~=nil
end
function M.assert_run(db,id)
  assert(#rows(db,'SELECT id FROM retention_session_ids WHERE CAST(id AS TEXT)=?',{tostring(id)})==0,'retention_scope_deleted')
  local scope=M.run_scope(db,id);M.assert_scope(db,scope);return scope
end
function M.claim_run(db,id,scope)
  id=tostring(id)
  M.assert_run(db,id)
  local saved,found=M.run_scope(db,id)
  if found then
    assert(scope==nil or saved==scope,'retention_scope_mismatch')
    M.assert_scope(db,saved);return saved
  end
  -- Existing unowned rows cannot be relabelled by an ordinary observation.
  for _,name in ipairs({'evidence_events','durable_runs'}) do
    if exists(db,name) and #rows(db,'SELECT 1 FROM '..name..' WHERE '..(name=='durable_runs' and 'id' or 'run_id')..'=? LIMIT 1',{id})>0 then
      assert(scope==nil,'retention_legacy_migration_required')
    end
  end
  M.assert_scope(db,scope)
  if scope then checked(db:run('INSERT OR IGNORE INTO retention_scopes(scope) VALUES(?)',{scope})) end
  if scope then checked(db:run('INSERT INTO retention_runs(run_id,scope) VALUES(?,?)',{id,scope}))
  else checked(db:run('INSERT INTO retention_runs(run_id) VALUES(?)',{id})) end
  return scope
end
local function transaction(db,fn)
  local hook,mask,count=debug.gethook()
  if hook and count and count>0 then hook('count') end
  debug.sethook()
  local ok,value=pcall(function()
    checked(db:exec('BEGIN IMMEDIATE'))
    local success,result=pcall(fn)
    if success then success=pcall(function()checked(db:exec('COMMIT'))end) end
    if not success then db:exec('ROLLBACK');error('retention_storage_failed',0) end
    return result
  end)
  debug.sethook(hook,mask,count)
  if not ok then error('retention_storage_failed',0) end
  return value
end
-- Explicit host attestation for legacy runs. Never inferred from payload text.
function M.adopt_run(id,scope)
  scope_name(scope);local db=connection()
  return transaction(db,function()
    M.assert_scope(db,scope)
    local saved,found=M.run_scope(db,id)
    assert(not saved or saved==scope,'retention_scope_mismatch')
    checked(db:run('INSERT OR IGNORE INTO retention_scopes(scope) VALUES(?)',{scope}))
    if found then checked(db:run('UPDATE retention_runs SET scope=? WHERE run_id=?',{scope,tostring(id)}))
    else checked(db:run('INSERT INTO retention_runs(run_id,scope) VALUES(?,?)',{tostring(id),scope})) end
    -- Legacy artifact ownership is attested by the containing run's references.
    if exists(db,'evidence_events') then
      for _,row in ipairs(rows(db,'SELECT body FROM evidence_events WHERE run_id=?',{tostring(id)})) do
        for _,ref in ipairs(json.decode(row.body).artifact_refs or {}) do
          for _,other in ipairs(rows(db,'SELECT body FROM evidence_events WHERE run_id<>?',{tostring(id)})) do
            for _,other_ref in ipairs(json.decode(other.body).artifact_refs or {}) do
              assert(other_ref.id~=ref.id,'retention_artifact_shared')
            end
          end
          local owner=rows(db,'SELECT run_id FROM retention_artifacts WHERE id=?',{ref.id})[1]
          assert(not owner or owner.run_id==tostring(id),'retention_artifact_shared')
          checked(db:run('INSERT OR IGNORE INTO retention_artifacts(id,run_id) VALUES(?,?)',{ref.id,tostring(id)}))
        end
      end
    end
    return true
  end)
end
function M.configure_scope(scope,options)
  scope_name(scope);local db=connection();M.assert_scope(db,scope)
  local expires=options and options.expires_at
  assert(type(expires)=='number' and expires==expires and expires>=0 and expires<math.huge,'retention_expiry_required')
  checked(db:run('INSERT INTO retention_scopes(scope,expires_at) VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET expires_at=excluded.expires_at',{scope,expires}))
  return true
end
function M.pending()
  return rows(connection(),"SELECT id,scope,status,created FROM retention_outbox WHERE status='pending' ORDER BY created,id")
end
function M.delete_scope(scope)
  scope_name(scope);local db=connection()
  local evidence=require('evidence')
  if not evidence.status().redaction_blocked then
    assert(evidence.redact(scope)==scope,'retention_scope_sensitive')
  else
    -- Do not add a new possibly-secret label while redaction is fail-closed.
    -- Existing trusted ownership must still be deletable without clearing it.
    local known=false
    for _,name in ipairs({'retention_scopes','retention_cache','import_tombstones','import_sources'}) do
      if exists(db,name) and #rows(db,'SELECT 1 FROM '..name..' WHERE scope=? LIMIT 1',{scope})>0 then known=true end
    end
    for _,name in ipairs({'sessions','memory'}) do
      if exists(db,name) and #rows(db,"SELECT 1 FROM "..name.." WHERE COALESCE(project,'global')=? LIMIT 1",{scope})>0 then known=true end
    end
    assert(known,'retention_scope_unavailable')
  end
  local manifest=transaction(db,function()
    local now=os.time()
    -- Tombstone first, in the same transaction as removal and outbox creation.
    checked(db:run('INSERT INTO retention_scopes(scope,deleted_at) VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET deleted_at=COALESCE(deleted_at,excluded.deleted_at)',{scope,now}))
    checked(db:run('INSERT OR IGNORE INTO import_tombstones(scope) VALUES(?)',{scope}))
    local id=require('evidence').id('deletion')
    checked(db:run("INSERT OR IGNORE INTO retention_outbox(id,scope,status,created) VALUES(?,?,'pending',?)",{id,scope,now}))
    local out=rows(db,'SELECT id,status FROM retention_outbox WHERE scope=?',{scope})[1]
    local result={id=out.id,scope=scope,local_deleted=true,external_status=out.status,counts={},physical_erasure=false}
    local function remove(name,condition,args)
      if not exists(db,name) then return end
      local n=rows(db,'SELECT COUNT(*) AS n FROM '..name..' WHERE '..condition,args)[1].n
      checked(db:run('DELETE FROM '..name..' WHERE '..condition,args));result.counts[name]=(result.counts[name] or 0)+n
    end
    local owned='SELECT run_id FROM retention_runs WHERE scope=?'
    -- Existing sessions are trusted ownership, even if their native evidence
    -- predates scope recording. Never infer ownership from event payload text.
    if exists(db,'sessions') then
      owned=owned.." UNION SELECT CAST(id AS TEXT) FROM sessions WHERE COALESCE(project,'global')=(SELECT scope FROM retention_scopes WHERE scope=?1)"
    end
    checked(db:run('UPDATE retention_lineage SET invalid=1 WHERE run_id IN ('..owned..')',{scope}))
    -- Native pre-migration session events can have artifact refs without an
    -- ownership index. Their trusted session/run owner supplies the boundary.
    if exists(db,'evidence_events') then
      local ids={}
      for _,r in ipairs(rows(db,'SELECT body FROM evidence_events WHERE run_id IN ('..owned..')',{scope})) do
        for _,ref in ipairs(json.decode(r.body).artifact_refs or {}) do
          assert(type(ref.id)=='string','retention_artifact_invalid');ids[ref.id]=true
        end
      end
      if next(ids) then
        for _,r in ipairs(rows(db,'SELECT body FROM evidence_events WHERE run_id NOT IN ('..owned..')',{scope})) do
          for _,ref in ipairs(json.decode(r.body).artifact_refs or {}) do assert(not ids[ref.id],'retention_artifact_shared') end
        end
        for id in pairs(ids) do
          checked(db:run('INSERT OR IGNORE INTO retention_deleted_artifacts(id) VALUES(?)',{id}))
          remove('evidence_artifacts','id=?',{id})
        end
      end
    end
    remove('evidence_artifacts','id IN (SELECT id FROM retention_artifacts WHERE run_id IN ('..owned..'))',{scope})
    for _,name in ipairs({'evidence_events','evidence_gaps','durable_steps'}) do remove(name,'run_id IN ('..owned..')',{scope}) end
    remove('durable_runs','id IN ('..owned..')',{scope})
    remove('durable_cache','key IN (SELECT key FROM retention_cache WHERE scope=?)',{scope})
    for _,name in ipairs({'import_events','import_sources','import_refs','import_quarantine','import_checkpoints','import_aliases'}) do remove(name,'scope=?',{scope}) end
    remove('records','CAST(run_id AS TEXT) IN ('..owned..')',{scope})
    if exists(db,'sessions') then
      -- Project ownership is a store contract; NULL is the explicit global lane.
      local sessions="SELECT id FROM sessions WHERE COALESCE(project,'global')=?"
      remove('sessions_fts','rowid IN ('..sessions..')',{scope})
      remove('records','run_id IN ('..sessions..') OR agent_id IN ('..sessions..')',{scope,scope})
      remove('journal','from_id IN ('..sessions..') OR to_id IN ('..sessions..')',{scope,scope})
      -- Retain id-only ownership so late journal/record producers are blocked.
      for _,r in ipairs(rows(db,sessions,{scope})) do
        checked(db:run('INSERT OR IGNORE INTO retention_session_ids(id,scope) VALUES(?,?)',{r.id,scope}))
      end
      remove('sessions',"COALESCE(project,'global')=?",{scope})
    end
    remove('memory',"COALESCE(project,'global')=?",{scope})
    return result
  end)
  return manifest
end
function M.reconcile(adapter)
  assert(type(adapter)=='function','retention_adapter_required')
  local acknowledged=0
  for _,job in ipairs(M.pending()) do
    -- The adapter owns protocol and remote authentication. A bare true is not
    -- proof: acknowledge this exact durable deletion identifier explicitly.
    local id=job.id
    local ok,receipt=pcall(adapter,job)
    if ok and type(receipt)=='table' and receipt.acknowledged==true and receipt.id==id then
      checked(connection():run("UPDATE retention_outbox SET status='acknowledged' WHERE id=? AND status='pending'",{id}))
      acknowledged=acknowledged+1
    end
  end
  return {acknowledged=acknowledged,unresolved=M.pending()}
end
function M.sweep(now)
  now=now or os.time();assert(type(now)=='number' and now==now and now<math.huge,'retention_time_required')
  local result={deleted_scopes=0,counts={},unresolved={}}
  for _,r in ipairs(rows(connection(),'SELECT scope FROM retention_scopes WHERE deleted_at IS NULL AND expires_at<=?',{now})) do
    local m=M.delete_scope(r.scope);result.deleted_scopes=result.deleted_scopes+1
    for name,n in pairs(m.counts) do result.counts[name]=(result.counts[name] or 0)+n end
  end
  result.unresolved=M.pending();return result
end
function M.export_run(id,profile)
  assert(profile==nil or profile=='redacted','retention_export_profile_invalid')
  local ok,result=pcall(function()
    local db=connection();local evidence=require('evidence')
    return transaction(db,function()
    local scope=M.assert_run(db,id)
    local events
    -- Use this connection, not another module's optional fixture connection.
    assert(exists(db,'evidence_events'),'retention_evidence_missing')
    events={}
    for _,r in ipairs(rows(db,'SELECT body FROM evidence_events WHERE run_id=? ORDER BY seq',{tostring(id)})) do events[#events+1]=json.decode(r.body) end
    assert(#events>0,'retention_evidence_missing')
    local artifacts,pending,finished={},{},{}
    local incomplete=not scope or evidence.status().coverage~='observations_only'
    if exists(db,'evidence_gaps') and #rows(db,'SELECT run_id FROM evidence_gaps WHERE run_id=?',{tostring(id)})>0 then incomplete=true end
    if exists(db,'evidence_capture_state') and #rows(db,'SELECT id FROM evidence_capture_state WHERE id=1')>0 then incomplete=true end
    local function inspect(v)
      if type(v)~='table' then return end
      if v.start_capture and v.start_capture~='recorded' or v.coverage=='incomplete' or v.effects_incomplete==true then incomplete=true end
      if v.evidence_marker and v.evidence_marker~='redacted' and v.evidence_marker~='artifact' then incomplete=true end
      for _,x in pairs(v) do inspect(x) end
    end
    for _,e in ipairs(events) do
      local kind,phase=e.kind:match('^(.*)%.(start)$')
      if not kind then kind,phase=e.kind:match('^(.*)%.(terminal)$') end
      if phase then
        if not e.correlation_id then incomplete=true
        else
          local key=json.encode({kind,e.correlation_id,e.attempt_id or '1'})
          if phase=='start' then
            if pending[key] or finished[key] then incomplete=true end
            pending[key]=true
          else
            if not pending[key] or finished[key] then incomplete=true end
            pending[key]=nil;finished[key]=true
          end
        end
      end
      inspect(e)
      for _,ref in ipairs(e.artifact_refs or {}) do
        local row=rows(db,'SELECT body FROM evidence_artifacts WHERE id=?',{ref.id})[1]
        assert(row,'retention_artifact_missing');artifacts[ref.id]=json.decode(row.body);inspect(artifacts[ref.id])
      end
    end
    if next(pending) then incomplete=true end
    local artifact=evidence.redact{schema_version=1,profile='redacted',run_id=tostring(id),scope=scope,events=events,artifacts=artifacts}
    inspect(artifact)
    artifact.coverage=incomplete and 'incomplete' or 'observed'
    -- Observation export is never itself a successful evaluation/promotion.
    artifact.promotion_qualified=false;artifact.evidence_complete=not incomplete
    return artifact
    end)
  end)
  if not ok then return nil,'retention_export_unavailable' end
  return result
end
function M.register_lineage(id,run_ids)
  assert(type(id)=='string' and #id>0 and type(run_ids)=='table' and #run_ids>0,'retention_lineage_required')
  local db=connection()
  return transaction(db,function()
    for _,run_id in ipairs(run_ids) do
      assert(M.assert_run(db,run_id),'retention_scope_required')
      checked(db:run('INSERT OR IGNORE INTO retention_lineage(id,run_id) VALUES(?,?)',{id,tostring(run_id)}))
    end
    return true
  end)
end
function M.lineage(id)
  local list=rows(connection(),'SELECT run_id,invalid FROM retention_lineage WHERE id=?',{id})
  local valid=#list>0
  for _,r in ipairs(list) do
    local artifact=M.export_run(r.run_id)
    if r.invalid~=0 or not artifact or not artifact.evidence_complete then valid=false end
  end
  return {valid=valid,promotion_qualified=false,dependencies=list}
end
return M
