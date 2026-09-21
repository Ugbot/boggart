-- Trusted local JSONL import boundary. Imported text never grants authority.
local M={}
local json,uv,evidence=require('json'),require('uv'),require('evidence')
local hash=require('workflow').hash
local adapters={boggart=require('imports.boggart'),claude=require('imports.claude'),openai=require('imports.openai')}
local configured
local schema=[[
CREATE TABLE IF NOT EXISTS import_events(id TEXT PRIMARY KEY,scope TEXT NOT NULL,session TEXT NOT NULL,body TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS import_scope_session ON import_events(scope,session);
CREATE TABLE IF NOT EXISTS import_sources(id TEXT PRIMARY KEY,scope TEXT NOT NULL,body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS import_refs(id TEXT PRIMARY KEY,event_id TEXT,source_id TEXT NOT NULL,scope TEXT NOT NULL,body TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS import_event_refs ON import_refs(event_id);
CREATE TABLE IF NOT EXISTS import_quarantine(id TEXT PRIMARY KEY,source_id TEXT NOT NULL,scope TEXT NOT NULL,body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS import_checkpoints(source_id TEXT PRIMARY KEY,scope TEXT NOT NULL,body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS import_tombstones(scope TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS import_aliases(id TEXT PRIMARY KEY,scope TEXT NOT NULL,mirror_key TEXT NOT NULL,primary_id TEXT NOT NULL,logical_id TEXT NOT NULL,external_id TEXT NOT NULL,lane TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS import_alias_mirror ON import_aliases(mirror_key);
CREATE INDEX IF NOT EXISTS import_alias_primary ON import_aliases(primary_id);
CREATE INDEX IF NOT EXISTS import_alias_logical ON import_aliases(logical_id);
]]
local function checked(v) assert(v~=nil and v~=false,'import_storage_failed');return v end
local function db()
  local d=configured or (bog and bog.db);assert(d,'import_database_required');checked(d:exec(schema));require('evidence_retention').ensure(d);return d
end
function M.configure(o) assert(type(o)=='table' and o.db,'import_database_required');configured=o.db end
local function canonical(v)
  if type(v)~='table' then return json.encode(v) end
  local keys={};for k in pairs(v) do keys[#keys+1]=k end
  table.sort(keys,function(a,b)return tostring(a)<tostring(b) end)
  local out={};for _,k in ipairs(keys) do out[#out+1]=json.encode(type(k)..':'..tostring(k))..':'..canonical(v[k]) end
  return '{'..table.concat(out,',')..'}'
end
local function identity(...) return hash(canonical({...})) end
local function row(d,sql,args) return checked(d:query(sql,args))[1] end
local function transaction(d,fn)
  -- No yield/callback runs inside this short commit boundary.
  local hook,mask,count=debug.gethook()
  if hook and count and count>0 then hook('count') end
  debug.sethook()
  local ok,result=pcall(function()
    checked(d:exec('BEGIN IMMEDIATE'))
    local success,value=pcall(fn)
    if success then
      local committed=pcall(function()checked(d:exec('COMMIT'))end)
      if not committed then d:exec('ROLLBACK');error('import_storage_failed') end
      return value
    end
    d:exec('ROLLBACK');error('import_storage_failed')
  end)
  debug.sethook(hook,mask,count)
  if not ok then error('import_storage_failed',0) end
  return result
end
local function redactor(rules)
  assert(type(rules)=='table' and type(rules.literals)=='table','import_redaction_required')
  local bytes=0
  for _,v in ipairs(rules.literals) do assert(type(v)=='string' and #v>0 and #v<=8192,'import_redaction_invalid');bytes=bytes+#v end
  assert(#rules.literals<=256 and bytes<=65536,'import_redaction_limit')
  return function(value)
    local work=0
    local function clean(v)
      if type(v)=='string' then
        -- Match original bytes; overlapping literals cannot hide one another.
        local spans={}
        for _,secret in ipairs(rules.literals) do
          work=work+(#v+1)*(#secret+1);assert(work<=16777216,'import_redaction_limit')
          local at=1
          while true do local a,b=v:find(secret,at,true);if not a then break end
            spans[#spans+1]={a,b};assert(#spans<=20000,'import_redaction_limit');at=b+1 end
        end
        table.sort(spans,function(a,b)return a[1]<b[1] end)
        local out,at={},1
        for _,s in ipairs(spans) do if s[2]>=at then
          if s[1]>=at then out[#out+1]=v:sub(at,s[1]-1);out[#out+1]='[REDACTED]' end;at=s[2]+1
        end end
        out[#out+1]=v:sub(at);return table.concat(out)
      elseif type(v)=='table' then
        local out={};for k,x in pairs(v) do
          -- Do not rewrite keys into collisions; marker replaces sensitive keys.
          if type(k)~='string' or clean(k)==k then out[k]=clean(x) else out.import_omitted_key=true end
        end;return out
      end
      return v
    end
    return clean(evidence.redact(value))
  end
end
local function ingest(o)
  assert(type(o)=='table' and adapters[o.format],'import_format_required')
  assert(type(o.scope)=='string' and #o.scope>0 and #o.scope<=1024,'import_scope_required')
  local redact=redactor(o.redaction)
  assert(redact(o.scope)==o.scope,'import_scope_sensitive')
  assert(type(o.source)=='table' and type(o.source.path)=='string' and type(o.source.root)=='string','import_selected_root_required')
  local root=assert(uv.fs_realpath(o.source.root),'import_root_missing')
  local path=assert(uv.fs_realpath(o.source.path),'import_source_missing')
  if package.config:sub(1,1)=='\\' then root=root:gsub('\\','/');path=path:gsub('\\','/') end
  assert(path==root or path:sub(1,#root+1)==root..'/' or root=='/','import_outside_root')
  local stat=assert(uv.fs_stat(path),'import_source_missing');assert(stat.type=='file','import_regular_file_required')
  local max_bytes=o.max_bytes or 1048576;local max_records=o.max_records or 500
  assert(type(max_bytes)=='number' and max_bytes>=1 and max_bytes<=4194304 and max_bytes%1==0,'import_byte_limit')
  assert(type(max_records)=='number' and max_records>=1 and max_records<=2000 and max_records%1==0,'import_record_limit')
  -- Explicit bounded local exports, never an implicit home-directory scan.
  local f=assert(io.open(path,'rb'),'import_open_failed');local data=f:read(16777217) or '';f:close()
  assert(#data<=16777216,'import_source_limit')
  local source_hash=hash(data);local adapter=adapters[o.format]
  local policy_hash=hash(canonical(o.redaction))
  local source_id=identity(o.scope,o.format,path,o.source.session)
  local d=db()
  assert(not row(d,'SELECT scope FROM import_tombstones WHERE scope=?',{o.scope}),'import_scope_tombstoned')
  local prior=row(d,'SELECT body FROM import_checkpoints WHERE source_id=?',{source_id})
  local cp=prior and json.decode(prior.body) or {offset=0,line=0,counts={},session=o.source.session}
  assert(not cp.policy_hash or cp.policy_hash==policy_hash,'import_redaction_policy_changed')
  local reset=cp.offset>#data or cp.prefix_hash and hash(data:sub(1,cp.offset))~=cp.prefix_hash
  if reset then cp={offset=0,line=0,counts={},session=o.source.session} end
  local initial=prior and prior.body
  local pending={};local used=0;local partial=false
  while #pending<max_records and cp.offset<#data do
    local newline=data:find('\n',cp.offset+1,true)
    if not newline then partial=true;break end
    local size=newline-cp.offset
    if used+size>max_bytes and not (size>262144 and #pending==0) then break end
    local start=cp.offset;local raw=data:sub(start+1,newline-1)
    cp.offset=newline;cp.line=cp.line+1;used=used+size
    local ref={source_id=source_id,scope=o.scope,source_hash=source_hash,hash_algorithm='sha256',byte_offset=start,byte_end=newline,event_offset=cp.line,record_hash=hash(raw)}
    local item={ref=ref,events={}}
    if #raw>262144 then item.reason='record_limit'
    else
      local decoded_ok,r=pcall(json.decode,raw)
      if not decoded_ok or type(r)~='table' then item.reason='malformed_json'
      else
        local ok,events,session,reason=pcall(adapter.normalize,r)
        if not ok then item.reason='malformed_record'
        else
          if session~=nil then
            if type(session)~='string' and type(session)~='number' then item.reason='invalid_session'
            elseif cp.session and tostring(session)~=tostring(cp.session) then item.reason='session_mismatch'
            else cp.session=tostring(session) end
          end
          if not cp.session then item.reason='session_missing' end
          if not item.reason then
            item.reason=reason
            for _,e in ipairs(events) do
              local session_key=identity(o.scope,o.format,cp.session)
              local signature=identity(e.kind,e.role,e.value,e.content_omissions)
              local lane=e.lane or (r.type=='response_item' and 'response' or r.type=='event_msg' and 'completed' or 'default')
              local countkey=signature..':'..lane
              cp.counts[countkey]=(cp.counts[countkey] or 0)+1
              local key=e.external_id and identity(session_key,e.kind,e.external_id) or identity(session_key,signature,cp.counts[countkey])
              local value=e.value
              e.lane=nil
              local observed_id=e.external_id
              e.external_id=nil
              e.provenance=value==nil and 'missing' or 'observed'
              if type(value)=='table' and value.evidence_marker then
                e.value_provenance=value.evidence_marker=='artifact' and 'missing' or 'partial'
                e.coverage_reason='snapshot_'..tostring(value.evidence_marker)
              end
              e.identity_confidence=observed_id and 'observed_id' or 'inferred'
              e.source_event_id=observed_id
              e.field_provenance={timestamp=e.timestamp~=nil and 'observed' or 'missing',
                call_id=e.call_id~=nil and 'observed' or 'missing',parent=e.parent~=nil and 'observed' or 'missing'}
              e.id=key;e.session=session_key;e.scope=o.scope;e.origin='imported';e.format=o.format;e.adapter_version=adapter.version
              e.schema_version=1;e.verified=false;e.coverage='observations_only'
              e.output={provenance='missing'}
              if e.kind=='tool.result' then e.output={provenance=e.value_provenance or e.provenance} end
              if e.call_id then e.operation_id=identity(session_key,e.call_id) end
              local mirror
              if o.format=='openai' and e.kind=='message' and (lane=='response' or lane=='completed') then
                mirror={key=identity(session_key,signature,cp.counts[countkey]),lane=lane,
                  external_id=observed_id and identity(observed_id) or ''}
              end
              item.events[#item.events+1]={id=key,session=session_key,raw=e,mirror=mirror}

            end
          end
        end
      end
    end
    pending[#pending+1]=item
  end
  -- Learn every labelled credential before serializing any related observation.
  -- This includes source metadata in Boggart snapshots and duplicate variants.
  for _,item in ipairs(pending) do for _,event in ipairs(item.events) do evidence.redact(event.raw) end end
  assert(redact(o.scope)==o.scope,'import_scope_sensitive')
  for _,item in ipairs(pending) do for _,event in ipairs(item.events) do
    local raw=event.raw;local e=redact(raw)
    if raw.arguments_decoded then
      -- Never retain the original escaped bytes: literal matching cannot sanitize
      -- all JSON spellings of a credential. Reencode the sanitized structure.
      local changed=canonical(raw.decoded_arguments)~=canonical(e.decoded_arguments)
      e.value=json.encode(e.decoded_arguments)
      e.representation={kind='canonical_sanitized_json',original_bytes_preserved=false,
        provenance='inferred',redacted=changed}
      if changed then e.value_provenance='redacted' end
    end
    assert(e.id==event.id and e.scope==o.scope and e.session==event.session,'import_redaction_structure')
    event.body=json.encode(e);assert(#event.body<=1048576,'import_snapshot_limit');event.raw=nil
  end end
  cp.prefix_hash=hash(data:sub(1,cp.offset));cp.source_hash=source_hash;cp.policy_hash=policy_hash
  cp.partial=partial;cp.reset=not not reset;cp.source_id=source_id
  cp.blocked_record=cp.offset<#data and not partial and #pending<max_records
  -- Session/occurrence state is necessary for restart; reject sensitive identities.
  assert(not cp.session or redact(cp.session)==cp.session,'import_session_sensitive')
  local checkpoint=json.encode(cp)
  return transaction(d,function()
    assert(not row(d,'SELECT scope FROM import_tombstones WHERE scope=?',{o.scope}),'tombstoned')
    local current=row(d,'SELECT body FROM import_checkpoints WHERE source_id=?',{source_id})
    assert((current and current.body)==initial,'concurrent_checkpoint')
    local result={added=0,duplicates=0,quarantined=0,checkpoint=cp}
    checked(d:run('INSERT OR REPLACE INTO import_sources(id,scope,body) VALUES(?,?,?)',{source_id,o.scope,json.encode(redact({id=source_id,scope=o.scope,path=path,root=root,format=o.format,source_hash=source_hash,adapter_version=adapter.version}))}))
    for _,item in ipairs(pending) do
      local ref=item.ref
      if item.reason then
        local qid=identity(source_id,ref.record_hash,ref.byte_offset,item.reason)
        local q={reason=item.reason,provenance=ref}
        if not row(d,'SELECT id FROM import_quarantine WHERE id=?',{qid}) then
          checked(d:run('INSERT INTO import_quarantine(id,source_id,scope,body) VALUES(?,?,?,?)',{qid,source_id,o.scope,json.encode(q)}));result.quarantined=result.quarantined+1
        end
      end
      for _,e in ipairs(item.events) do
        if e.mirror then
          local m=e.mirror;local primary=e.id;local target
          -- Explicit IDs retain their existing logical target even on replay or
          -- differing observations. Otherwise pair only opposite mirror lanes.
          local same=checked(d:query('SELECT logical_id FROM import_aliases WHERE primary_id=?',{primary}))
          for _,a in ipairs(same) do
            if target and target~=a.logical_id then error('import_alias_ambiguous') end
            target=a.logical_id
          end
          if not target then
            local candidates=checked(d:query('SELECT logical_id,external_id,lane FROM import_aliases WHERE mirror_key=?',{m.key}))
            local ambiguous=false
            for _,a in ipairs(candidates) do
              local compatible=true
              if m.external_id~='' then
                for _,known in ipairs(checked(d:query('SELECT external_id FROM import_aliases WHERE logical_id=? AND external_id<>?',{a.logical_id,''}))) do
                  if known.external_id~=m.external_id then compatible=false end
                end
              end
              if compatible and a.lane~=m.lane and (m.external_id=='' or a.external_id=='' or m.external_id==a.external_id) then
                if target and target~=a.logical_id then ambiguous=true end;target=a.logical_id
              end
            end
            if ambiguous then target=nil end
          end
          if target and target~=e.id then
            e.id=target;local normalized=json.decode(e.body);normalized.id=target
            normalized.identity_confidence='inferred_mirror';e.body=json.encode(normalized)
          end
          checked(d:run('INSERT OR IGNORE INTO import_aliases(id,scope,mirror_key,primary_id,logical_id,external_id,lane) VALUES(?,?,?,?,?,?,?)',
            {identity(m.key,primary,m.lane),o.scope,m.key,primary,e.id,m.external_id,m.lane}))
        end
        local prior_event=row(d,'SELECT body FROM import_events WHERE id=?',{e.id})
        local reference={};for k,v in pairs(ref) do reference[k]=v end
        if prior_event then
          result.duplicates=result.duplicates+1
          if canonical(json.decode(prior_event.body))~=canonical(json.decode(e.body)) then
            reference.observed_variant=json.decode(e.body)
            reference.coverage='alternate_observation'
          end
        else
          checked(d:run('INSERT INTO import_events(id,scope,session,body) VALUES(?,?,?,?)',{e.id,o.scope,e.session,e.body}));result.added=result.added+1
        end
        local rid=identity(source_id,source_hash,ref.byte_offset,e.id)
        checked(d:run('INSERT OR IGNORE INTO import_refs(id,event_id,source_id,scope,body) VALUES(?,?,?,?,?)',{rid,e.id,source_id,o.scope,json.encode(reference)}))
      end
    end
    checked(d:run('INSERT OR REPLACE INTO import_checkpoints(source_id,scope,body) VALUES(?,?,?)',{source_id,o.scope,checkpoint}))
    return result
  end)
end
function M.ingest(options)
  local ok,result=pcall(ingest,options)
  if not ok then return nil,tostring(result):match('(import_[%w_]+)') or 'import_failed' end -- fixed codes only
  return result
end
function M.read(scope)
  assert(type(scope)=='string' and #scope>0,'import_scope_required')
  local d=db();local out,results={},{}
  for _,r in ipairs(checked(d:query('SELECT body FROM import_events WHERE scope=? ORDER BY rowid',{scope}))) do
    local e=json.decode(r.body);out[#out+1]=e
    if e.kind=='tool.result' and e.operation_id then results[e.operation_id]=e end
    e.source_refs={}
    e.observed_ids={};local ids={}
    local function observed(id) if id and not ids[id] then ids[id]=true;e.observed_ids[#e.observed_ids+1]=id end end
    observed(e.source_event_id)
    for _,ref in ipairs(checked(d:query('SELECT body FROM import_refs WHERE event_id=?',{e.id}))) do
      local reference=json.decode(ref.body);e.source_refs[#e.source_refs+1]=reference
      if reference.observed_variant then observed(reference.observed_variant.source_event_id) end
    end
  end
  for _,e in ipairs(out) do
    if e.kind=='tool.request' and results[e.operation_id] then
      local result=results[e.operation_id];e.output={provenance=result.value_provenance or result.provenance,event_id=result.id}
    end
  end
  return out
end
function M.quarantine(scope)
  local out={};for _,r in ipairs(checked(db():query('SELECT body FROM import_quarantine WHERE scope=? ORDER BY rowid',{scope}))) do out[#out+1]=json.decode(r.body) end;return out
end
-- Retention integration seam: block reimport before a downstream deletion sweep.
function M.tombstone(scope)
  assert(type(scope)=='string' and #scope>0,'import_scope_required')
  checked(db():run('INSERT OR IGNORE INTO import_tombstones(scope) VALUES(?)',{scope}));return true
end
return M
