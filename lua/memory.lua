-- memory.lua -- durable, cross-session memory, backed by the SQLite store
-- (see store.lua). The system prompt gets an index of titles + previews;
-- recall uses FTS5. The remember/recall/forget tool interface is unchanged.
local M = {}

-- The project a memory operation belongs to. Everything here is scoped to the
-- CURRENT project, with `global` readable underneath and ranked below it (the
-- rule lives in store.lua's SQL). A memory written while working on one story
-- is therefore invisible to another, which is the entire point.
local function here()
  local ok, proj = pcall(require, "project")
  return ok and proj.current() or nil
end
M.scope = here

function M.list()
  local out = {}
  for _, row in ipairs(bog.store.mem_list(here())) do
    local preview = (row.body or ""):gsub("%s+", " "):sub(1, 100)
    -- A global memory surfacing inside a project is labelled, so you can see
    -- where an answer came from and demote or forget it.
    -- `is_global`, not `global`: Lua 5.5 made `global` a keyword, so it cannot
    -- be a bare key in a table constructor.
    out[#out + 1] = { title = row.title, preview = preview, body = row.body,
                      project = row.project, is_global = (row.project == nil) }
  end
  return out
end

function M.index_text()
  local items = M.list()
  if #items == 0 then
    return "(no stored memories yet -- use the remember tool to save durable facts)"
  end
  local parts = {}
  for _, it in ipairs(items) do
    parts[#parts + 1] = string.format("- %s: %s", it.title, it.preview)
  end
  return table.concat(parts, "\n")
end

-- Writes land in the current project. Promotion to global is a separate,
-- explicit act -- the opposite default would recreate exactly the bleed
-- projects exist to stop.
function M.remember(title, body) return bog.store.mem_put(title, body, here()) end

function M.recall(query)
  local rows = bog.store.mem_search(query, here())
  local parts = {}
  for _, r in ipairs(rows) do
    local head = "# " .. r.title
    if r.project == nil and not (require("project").is_global()) then
      head = head .. "   (global)"
    end
    parts[#parts + 1] = head .. "\n" .. (r.body or "")
  end
  return table.concat(parts, "\n\n---\n\n")
end

-- Forget within this project; global memories are only forgotten from global.
function M.forget(title) return bog.store.mem_del(title, here()) end

-- The explicit promotion: move a memory from this project into global, where
-- every project can read it.
function M.promote(title) return bog.store.mem_promote(title, here()) end

-- Tool definitions contributed to the registry by tools.lua.
M.tools = {
  remember = {
    description = "Save a durable fact to long-term memory (SQLite-backed) so it survives across "
      .. "sessions. Use for user preferences, project facts, decisions, and anything worth "
      .. "remembering later. Re-using a title overwrites that memory.",
    input_schema = {
      type = "object",
      properties = {
        title = { type = "string", description = "Short unique title (the key)." },
        body = { type = "string", description = "The full note to store." },
      },
      required = { "title", "body" },
    },
    run = function(a)
      if type(a.title) ~= "string" or a.title == "" then return "Tool error: remember requires a 'title'" end
      M.remember(a.title, a.body or "")
      return "Remembered: " .. a.title
    end,
  },
  recall = {
    description = "Search stored memories by full-text query (FTS5). With no query, returns all "
      .. "of them, most-recent first.",
    input_schema = {
      type = "object",
      properties = { query = { type = "string", description = "Optional full-text query." } },
    },
    run = function(a)
      local text = M.recall(a.query)
      if text == "" then return "(no matching memories)" end
      return text
    end,
  },
  forget = {
    description = "Delete a stored memory by its exact title.",
    input_schema = {
      type = "object",
      properties = { title = { type = "string" } },
      required = { "title" },
    },
    run = function(a)
      if M.forget(a.title or "") then return "Forgot: " .. tostring(a.title) end
      return "Tool error: no memory titled " .. tostring(a.title)
    end,
  },
}

-- Scoped process/evidence index. Construction and installation are host-only;
-- generated workflows receive the resulting narrow functions, never open().
local json=require('json')
local function checked(v,e) assert(v~=nil and v~=false,e or 'memory_storage_failed');return v end
local function rows(db,sql,args) return checked(db:query(sql,args)) end
local function transaction(db,fn)
  checked(db:exec('BEGIN IMMEDIATE'))
  local ok,result=pcall(fn)
  if ok then checked(db:exec('COMMIT'));return result end
  db:exec('ROLLBACK');error(result,0)
end
local function schema(db)
  require('evidence_retention').ensure(db)
  checked(db:exec([[
CREATE TABLE IF NOT EXISTS scoped_memory(scope TEXT NOT NULL,source_id TEXT NOT NULL,revision INTEGER NOT NULL,acked INTEGER NOT NULL DEFAULT 0,deleted INTEGER NOT NULL DEFAULT 0,body TEXT NOT NULL,PRIMARY KEY(scope,source_id));
CREATE TABLE IF NOT EXISTS scoped_memory_identity(id INTEGER PRIMARY KEY CHECK(id=1),namespace TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS scoped_memory_sync(scope TEXT PRIMARY KEY,token TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS scoped_memory_deleted_sources(scope TEXT NOT NULL,source_ref TEXT NOT NULL,PRIMARY KEY(scope,source_ref));
CREATE TABLE IF NOT EXISTS scoped_memory_refs(scope TEXT NOT NULL,source_id TEXT NOT NULL,source_ref TEXT NOT NULL,PRIMARY KEY(scope,source_id,source_ref));
CREATE TRIGGER IF NOT EXISTS scoped_memory_scope_delete AFTER UPDATE OF deleted_at ON retention_scopes WHEN NEW.deleted_at IS NOT NULL BEGIN
 UPDATE scoped_memory SET deleted=1,body='{}',revision=revision+1 WHERE scope=NEW.scope AND deleted=0;
 DELETE FROM scoped_memory_refs WHERE scope=NEW.scope;
 DELETE FROM scoped_memory_deleted_sources WHERE scope=NEW.scope;
END;
CREATE TRIGGER IF NOT EXISTS scoped_memory_scope_insert AFTER INSERT ON retention_scopes WHEN NEW.deleted_at IS NOT NULL BEGIN
 UPDATE scoped_memory SET deleted=1,body='{}',revision=revision+1 WHERE scope=NEW.scope AND deleted=0;
 DELETE FROM scoped_memory_refs WHERE scope=NEW.scope;
 DELETE FROM scoped_memory_deleted_sources WHERE scope=NEW.scope;
END;
CREATE TRIGGER IF NOT EXISTS scoped_memory_import_delete AFTER INSERT ON import_tombstones BEGIN
 UPDATE scoped_memory SET deleted=1,body='{}',revision=revision+1 WHERE scope=NEW.scope AND deleted=0;
 DELETE FROM scoped_memory_refs WHERE scope=NEW.scope;
 DELETE FROM scoped_memory_deleted_sources WHERE scope=NEW.scope;
END;
CREATE TRIGGER IF NOT EXISTS scoped_memory_fence_insert BEFORE INSERT ON scoped_memory WHEN NEW.deleted=0 AND (EXISTS(SELECT 1 FROM retention_scopes WHERE scope=NEW.scope AND deleted_at IS NOT NULL) OR EXISTS(SELECT 1 FROM import_tombstones WHERE scope=NEW.scope)) BEGIN SELECT RAISE(ABORT,'retention_scope_deleted'); END;
CREATE TRIGGER IF NOT EXISTS scoped_memory_fence_update BEFORE UPDATE ON scoped_memory WHEN NEW.deleted=0 AND (EXISTS(SELECT 1 FROM retention_scopes WHERE scope=NEW.scope AND deleted_at IS NOT NULL) OR EXISTS(SELECT 1 FROM import_tombstones WHERE scope=NEW.scope)) BEGIN SELECT RAISE(ABORT,'retention_scope_deleted'); END;
]]))
  checked(db:run('INSERT OR IGNORE INTO scoped_memory_identity(id,namespace) VALUES(1,?)',{require('evidence').id('memory')}))
end
local filter_fields={kind=true,code_version=true,step=true,dependency=true,context_ref=true,relation=true,target=true,source_ref=true}
local function scalar(s,name)
  assert(type(s)=='string' and #s>0 and #s<=1024,'invalid '..name);return s
end
local function canonical(value,depth)
  if type(value)~='table' then return json.encode(value) end
  depth=(depth or 0)+1;assert(depth<=16,'memory metadata too deep')
  local keys,array={},true
  for key in pairs(value) do keys[#keys+1]=key;if type(key)~='number' or key%1~=0 or key<1 then array=false end end
  if array and #keys>0 then
    local out={};for i=1,#keys do assert(value[i]~=nil,'sparse memory metadata');out[i]=canonical(value[i],depth) end
    return '['..table.concat(out,',')..']'
  end
  for _,key in ipairs(keys) do assert(type(key)=='string','invalid metadata key') end
  table.sort(keys);local out={}
  for _,key in ipairs(keys) do out[#out+1]=json.encode(key)..':'..canonical(value[key],depth) end
  return '{'..table.concat(out,',')..'}'
end
local function matches(doc,filters)
  for k,v in pairs(filters) do if doc[k]~=v then return false end end
  return true
end
function M.open(options)
  assert(type(options)=='table','host options required')
  local db=assert(options.db or (bog and bog.db),'memory database required')
  local scope=scalar(options.scope,'host scope')
  assert(type(options.authorize)=='function','host authority callback required')
  local retention,evidence=require('evidence_retention'),require('evidence')
  schema(db);retention.assert_scope(db,scope)
  assert(evidence.redact(scope)==scope,'sensitive scope')
  checked(db:run('INSERT OR IGNORE INTO retention_scopes(scope) VALUES(?)',{scope}))
  local namespace=rows(db,'SELECT namespace FROM scoped_memory_identity WHERE id=1')[1].namespace
  local adapter=options.adapter
  if options.export==true and not adapter then
    adapter=require('adapters.gestalt').new{scope=scope,namespace=namespace,base_url=options.base_url,
      api_key=options.api_key,timeout=options.timeout,capability_prefix=options.capability_prefix}
  end
  assert(not adapter or adapter.scope==scope,'adapter scope mismatch')
  local self={scope=scope,namespace=namespace}
  local function authorized(requested,deleted_ok,operation)
    assert(requested==nil or requested==scope,'memory_scope_denied')
    local inherited=require('invoke').correlation().scope
    assert(inherited==nil or inherited==scope,'memory_scope_denied')
    assert(options.authorize(scope,operation or 'read')==true,'memory_scope_denied')
    if not deleted_ok then retention.assert_scope(db,scope) end
  end
  local function get(id) return rows(db,'SELECT * FROM scoped_memory WHERE scope=? AND source_id=?',{scope,id})[1] end
  function self:put(document)
    authorized(nil,false,'write');assert(type(document)=='table','document required')
    local doc=evidence.redact(document)
    scalar(doc.source_id,'source_id');scalar(doc.source_ref,'source_ref')
    assert(doc.source_id==document.source_id and doc.source_ref==document.source_ref,'sensitive source identity')
    assert(type(doc.text)=='string' and #doc.text<=65536,'bounded text required')
    assert(doc.scope==nil or doc.scope==scope,'memory_scope_denied')
    if doc.run_id then assert(retention.assert_run(db,doc.run_id)==scope,'source run scope mismatch') end
    doc.scope=scope;doc.revision=nil
    for k in pairs(filter_fields) do if doc[k]~=nil then scalar(doc[k],k) end end
    if doc.source_span then
      assert(type(doc.source_span)=='table' and type(doc.source_span.start)=='number' and type(doc.source_span.finish)=='number'
        and doc.source_span.start>=0 and doc.source_span.finish>=doc.source_span.start,'invalid source span')
    end
    local encoded=canonical(doc);assert(#encoded<=131072,'memory document too large')
    return transaction(db,function()
      authorized(nil,false,'write')
      assert(#rows(db,'SELECT 1 FROM scoped_memory_deleted_sources WHERE scope=? AND source_ref=?',{scope,doc.source_ref})==0,'source_deleted')
      for _,ref in ipairs(doc.source_refs or {}) do assert(#rows(db,'SELECT 1 FROM scoped_memory_deleted_sources WHERE scope=? AND source_ref=?',{scope,ref})==0,'source_deleted') end
      local previous=get(doc.source_id)
      if previous and previous.deleted==0 and previous.body==encoded then return previous.revision end
      local revision=(previous and previous.revision or 0)+1
      checked(db:run('INSERT INTO scoped_memory(scope,source_id,revision,body) VALUES(?,?,?,?) ON CONFLICT(scope,source_id) DO UPDATE SET revision=excluded.revision,body=excluded.body,deleted=0',{scope,doc.source_id,revision,encoded}))
      checked(db:run('DELETE FROM scoped_memory_refs WHERE scope=? AND source_id=?',{scope,doc.source_id}))
      local refs={doc.source_ref}
      for i,ref in ipairs(doc.source_refs or {}) do assert(i<=64,'too many source refs');refs[#refs+1]=scalar(ref,'source reference') end
      for _,ref in ipairs(refs) do checked(db:run('INSERT OR IGNORE INTO scoped_memory_refs VALUES(?,?,?)',{scope,doc.source_id,ref})) end
      return revision
    end)
  end
  function self:remove(source_id)
    authorized(nil,true,'write');scalar(source_id,'source_id')
    return transaction(db,function()
      local old=get(source_id)
      if old and old.deleted~=0 then return old.revision end
      local revision=(old and old.revision or 0)+1
      checked(db:run("INSERT INTO scoped_memory(scope,source_id,revision,deleted,body) VALUES(?,?,?,1,'{}') ON CONFLICT(scope,source_id) DO UPDATE SET revision=excluded.revision,deleted=1,body='{}'",{scope,source_id,revision}))
      return revision
    end)
  end
  function self:remove_source(source_ref)
    authorized(nil,true,'write');scalar(source_ref,'source_ref')
    return transaction(db,function()
      checked(db:run('INSERT OR IGNORE INTO scoped_memory_deleted_sources VALUES(?,?)',{scope,source_ref}))
      checked(db:run("UPDATE scoped_memory SET deleted=1,body='{}',revision=revision+1 WHERE scope=? AND deleted=0 AND source_id IN (SELECT source_id FROM scoped_memory_refs WHERE scope=? AND source_ref=?)",{scope,scope,source_ref}))
      return true
    end)
  end
  local function pending()
    return rows(db,'SELECT COUNT(*) AS n FROM scoped_memory WHERE scope=? AND revision<>acked',{scope})[1].n
  end
  local function hydrate(row)
    local doc=json.decode(row.body);doc.revision=row.revision;doc.scope=scope
    return doc
  end
  function self:search(query,opts)
    opts=opts or {};authorized(opts.scope)
    query=query or '';assert(type(query)=='string' and #query<=4096,'invalid query')
    local limit=opts.limit or 10;assert(type(limit)=='number' and limit%1==0 and limit>=1 and limit<=100,'invalid limit')
    local filters=opts.filters or {}
    for k,v in pairs(filters) do assert(filter_fields[k],'unsupported filter');scalar(v,k) end
    local coverage={pending=pending(),advanced='unavailable',vector=false,graph='relation_fields_only',stale_rejected=0}
    local out={hits={},provenance={},backend='local',coverage=coverage}
    if opts.mode and opts.mode~='text' then coverage.reason='unsupported_search_mode';return out end
    if adapter and options.export==true then
      local clause=query=='' and {match_all={}} or {match={text=query}}
      local clauses={};for k,v in pairs(filters) do clauses[#clauses+1]={term={[k]=v}} end
      local body={size=limit,query=next(filters) and {bool={must={clause},filter=clauses}} or clause}
      local response=adapter:call(options.context,'search',body)
      if response.status=='succeeded' then
        authorized(opts.scope)
        out.backend='gestalt';coverage.advanced='available';coverage.text='whole_document_bm25'
        for _,hit in ipairs(response.result.hits.hits) do
          local source=hit._source
          local row=type(source)=='table' and source.scope==scope and type(source.source_id)=='string' and get(source.source_id)
          if row and row.deleted==0 and row.revision==source.revision and hit._id==require('workflow').hash(source.source_id) then
            local doc=hydrate(row)
            if matches(doc,filters) then doc.score=hit._score;out.hits[#out.hits+1]=doc end
          else coverage.stale_rejected=coverage.stale_rejected+1 end
        end
      else coverage.reason=response.status;coverage.error=response.error and response.error.code end
    else coverage.reason='export_not_enabled' end
    if out.backend=='local' then
      authorized(opts.scope)
      -- Bound the fallback, and declare truncation; this is substring lookup,
      -- never a made-up BM25/vector score.
      local candidates=rows(db,'SELECT * FROM scoped_memory WHERE scope=? AND deleted=0 ORDER BY source_id LIMIT 257',{scope})
      coverage.local_truncated=#candidates>256;coverage.text='literal_substring'
      for i,row in ipairs(candidates) do
        if i>256 or #out.hits>=limit then break end
        local doc=hydrate(row)
        if matches(doc,filters) and (query=='' or doc.text:lower():find(query:lower(),1,true)) then out.hits[#out.hits+1]=doc end
      end
    end
    for _,doc in ipairs(out.hits) do out.provenance[#out.provenance+1]={source_id=doc.source_id,source_ref=doc.source_ref,source_span=doc.source_span,scope=scope,revision=doc.revision} end
    coverage.complete=false -- no completeness claim for ranked/bounded retrieval
    return out
  end
  function self:sync(cursor)
    authorized(cursor and cursor.scope,true,'sync')
    local checkpoint={scope=scope,namespace=namespace,pending=pending(),acknowledged=0,status='unavailable'}
    if not adapter or options.export~=true then checkpoint.reason='export_not_enabled';return checkpoint end
    local token=evidence.id('sync')
    checked(db:run('INSERT OR IGNORE INTO scoped_memory_sync(scope,token) VALUES(?,?)',{scope,token}))
    local owner=rows(db,'SELECT token FROM scoped_memory_sync WHERE scope=?',{scope})[1].token
    if owner~=token then checkpoint.status='busy';checkpoint.owner=owner;return checkpoint end
    local ok,err=pcall(function()
      local batch=rows(db,'SELECT * FROM scoped_memory WHERE scope=? AND revision<>acked ORDER BY source_id LIMIT 32',{scope})
      checkpoint.status='succeeded'
      for _,row in ipairs(batch) do
        authorized(nil,true)
        local current=get(row.source_id)
        local deleted=current.deleted~=0
        if not deleted then authorized() end
        local doc=deleted and {source_id=current.source_id} or hydrate(current)
        authorized(nil,true,'sync')
        local response=adapter:call(options.context,deleted and 'delete' or 'put',doc)
        if response.status~='succeeded' then checkpoint.status=response.status;checkpoint.error=response.error;break end
        checked(db:run('UPDATE scoped_memory SET acked=? WHERE scope=? AND source_id=? AND revision=?',{current.revision,scope,current.source_id,current.revision}))
        checkpoint.acknowledged=checkpoint.acknowledged+1
      end
    end)
    if not ok then checkpoint.status='uncertain';checkpoint.error={code='sync_failed'} end
    if checkpoint.status=='uncertain' then
      -- A timed-out remote write may still arrive. Do not admit a newer write
      -- until the host proves the old producer AND remote requests quiescent.
      checkpoint.owner=token
    else checked(db:run('DELETE FROM scoped_memory_sync WHERE scope=? AND token=?',{scope,token})) end
    checkpoint.pending=pending();return checkpoint
  end
  -- Host must stop/exclude the owner AND quiesce every issued remote request.
  -- No timeout or local PID check alone can establish
  -- that fact for a remote write; automatic lease stealing is deliberately absent.
  function self:recover_sync(token)
    authorized(nil,true,'recover');scalar(token,'sync token')
    assert(type(options.confirm_stopped)=='function' and options.confirm_stopped(token)==true,'sync_owner_not_proven_stopped')
    checked(db:run('DELETE FROM scoped_memory_sync WHERE scope=? AND token=?',{scope,token}));return true
  end
  function self:features() return adapter and adapter:features() or {advanced='unavailable',text='literal_substring'} end
  return self
end
local installed
function M.install(port) assert(type(port)=='table' and type(port.search)=='function','host memory port required');installed=port end
function M.search(query,opts) assert(installed,'host memory port not installed');return installed:search(query,opts) end
function M.sync(cursor) assert(installed,'host memory port not installed');return installed:sync(cursor) end

return M
