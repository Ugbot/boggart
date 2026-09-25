-- Durable occasions, private host bindings, and a single admission path.
local M={}
local json,invoke=require('json'),require('invoke')
local function must(v,e)assert(v~=nil and v~=false,type(e)=='string' and e or 'trigger_database');return v end
local function copy(v)return json.decode(json.encode(v))end
local function protect(fn)local ok,a,b=pcall(fn);if ok then return a,b end;return nil,type(a)=='table' and a or {code=tostring(a)}end
function M.open(opts)
 assert(opts and opts.db,'trigger_database_required')
 local db=opts.db;local host={};local handles={};local queued={};local hooks={}
 must(db:exec([[PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS workflow_triggers(id TEXT PRIMARY KEY,body TEXT NOT NULL,enabled INTEGER NOT NULL,next_at INTEGER,last_at INTEGER);
CREATE TABLE IF NOT EXISTS workflow_occurrences(trigger_id TEXT NOT NULL,occurrence TEXT NOT NULL,status TEXT NOT NULL,run_id TEXT,body TEXT NOT NULL,PRIMARY KEY(trigger_id,occurrence));
]]))
 local function rows(sql,args)return must(db:query(sql,args))end
 local function sql(q,a)return must(db:run(q,a))end
 local function tx(fn)
  must(db:exec('BEGIN IMMEDIATE'));local ok,a,b=pcall(fn)
  if ok and db:exec('COMMIT')then return a,b end
  pcall(db.exec,db,'ROLLBACK');error(ok and 'trigger_database' or a,0)
 end
 local function get(id)
  local r=rows('SELECT * FROM workflow_triggers WHERE id=?',{id})[1]
  if r then r.config=json.decode(r.body)end;return r
 end
 local function next_time(c,now)
  if not c.schedule then return nil end
  if c.schedule.every then return now+c.schedule.every end
  return require('trigger_timezone').next(c.schedule.at,c.timezone,now)
 end
 local r={}
 function r:bind(o)
  return protect(function()
   local supplied=o;o={};for k,v in pairs(supplied) do o[k]=v end
   o.id=o.id or o.workflow;o.registry=o.registry or opts.registry
   o.authority=o.authority or opts.authority;o.project=o.project or opts.project
   assert(type(o.id)=='string' and o.id~='' and type(o.workflow)=='string','trigger_binding_invalid')
   assert(o.registry and type(o.registry.start)=='function' and type(o.authority)=='function','trigger_host_binding_required')
   assert(o.context_provider==nil or type(o.context_provider)=='table','context_provider_must_be_bindings')
   local overlap=o.overlap or 1;assert(overlap==1,'trigger_overlap_unsupported')
   local misfire=o.misfire or 'skip';assert(misfire=='skip' or misfire=='once','trigger_misfire_invalid')
   if o.schedule then
    assert(type(o.schedule)=='table' and (o.schedule.every==nil)~=(o.schedule.at==nil),'trigger_schedule_invalid')
    if o.schedule.every then assert(type(o.schedule.every)=='number' and o.schedule.every>=1 and o.schedule.every%1==0,'trigger_interval_invalid')
    else require('trigger_timezone').next(o.schedule.at,assert(o.timezone,'timezone_required'),opts.now and opts.now() or os.time())end
   end
   local authority=o.authority();assert(authority,'trigger_authority_unavailable')
   if o.policy_scope then authority=invoke.context({policy_scopes={o.policy_scope}},authority)end
   local restrictions=invoke.durable_restrictions(authority)
   local c={id=o.id,workflow=o.workflow,project=o.project,execution_profile=o.execution_profile,schedule=o.schedule,on=o.on,timezone=o.timezone or 'UTC',overlap=overlap,misfire=misfire,restrictions=restrictions}
   local record=tx(function()
    local old=get(o.id)
    if old then
     -- Identity is immutable: a changed definition needs a new ID. Retain the
     -- original floor even when a host reconnects with broader authority.
     local prior=old.config
     for _,k in ipairs({'workflow','project','timezone','overlap','misfire','on','execution_profile'})do assert(prior[k]==c[k],'trigger_identity_conflict:'..k)end
     assert(json.encode(prior.schedule)==json.encode(c.schedule),'trigger_identity_conflict:schedule')
     return old
    end
    local now=opts.now and opts.now() or os.time()
    sql('INSERT INTO workflow_triggers(id,body,enabled,next_at) VALUES(?,?,1,?)',{o.id,json.encode(c),next_time(c,now)})
    return get(o.id)
   end)
   host[o.id]={registry=o.registry,authority=o.authority,context=o.context_provider or {},policy_scope=o.policy_scope}
   if hooks[o.id] then bog.events.off(hooks[o.id]);hooks[o.id]=nil end
   if o.on then
    assert(type(o.on)=='string' and o.on:match('^hook:[%w_.-]+$'),'trigger_hook_invalid')
    hooks[o.id]=bog.events.on(o.on,function(_,event)
     self:enqueue(o.id,require('evidence').id('hook-occasion'),'hook',event)
    end)
   end
   return self:status(o.id)
  end)
 end
 local function authority(id,record)
  local b=assert(host[id],'trigger_binding_unavailable')
  local a=assert(b.authority(),'trigger_authority_unavailable')
  if b.policy_scope then a=invoke.context({policy_scopes={b.policy_scope}},a)end
  return invoke.restrict_durable(a,record.config.restrictions)
 end
 function r:preview(id)
  local record=get(id);if not record then return nil,{code='trigger_missing'}end
  -- No registry select: that pins a run and invokes admission callbacks.
  return {id=id,workflow=record.config.workflow,timezone=record.config.timezone,next_at=record.next_at,
   misfire=record.config.misfire,overlap=record.config.overlap,execution_profile=record.config.execution_profile,on=record.config.on,
   error=record.config.error,enabled=record.enabled==1,available=host[id]~=nil,schedule=copy(record.config.schedule),effects=false}
 end
 function r:status(id)
  if id then
   local value=self:preview(id);if not value then return nil end
   local record=get(id);value.last_at=record.last_at
   value.occurrences=rows('SELECT occurrence,status,run_id,body FROM workflow_occurrences WHERE trigger_id=? ORDER BY rowid',{id})
   for _,occ in ipairs(value.occurrences)do occ.detail=json.decode(occ.body);occ.body=nil end
   return value
  end
  local out={};for _,record in ipairs(rows('SELECT id FROM workflow_triggers ORDER BY id'))do out[#out+1]=self:status(record.id)end;return out
 end
 function r:pause(id,paused)
  return protect(function()assert(get(id),'trigger_missing');sql('UPDATE workflow_triggers SET enabled=? WHERE id=?',{paused==false and 1 or 0,id});return true end)
 end
 local function set_status(id,occ,status,run_id,detail)
  local old=rows('SELECT body FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1]
  local body=old and json.decode(old.body) or {}
  for k,v in pairs(detail or {}) do body[k]=v end
  sql('UPDATE workflow_occurrences SET status=?,run_id=?,body=? WHERE trigger_id=? AND occurrence=?',{status,run_id,json.encode(body),id,occ})
 end
 function r:claim(id,occ,origin,event)
  return protect(function()
   assert(type(occ)=='string' and #occ>0 and #occ<=256,'occurrence_invalid')
   assert(origin=='named' or origin=='button' or origin=='timer' or origin=='hook','origin_invalid')
   return tx(function()
    local record=assert(get(id),'trigger_missing');assert(record.enabled==1,'trigger_paused')
    assert(host[id],'trigger_binding_unavailable')
    if rows('SELECT occurrence FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1]then return false,{code='occurrence_exists'}end
    local active=rows("SELECT occurrence FROM workflow_occurrences WHERE trigger_id=? AND status IN ('claimed','dispatching','suspended','uncertain','recovering','cancel_requested')",{id})
    if #active>=record.config.overlap then return false,{code='trigger_overlap'}end
    sql('INSERT INTO workflow_occurrences(trigger_id,occurrence,status,body) VALUES(?,?,?,?)',{id,occ,'claimed',json.encode({origin=origin,owner=require('evidence').id('occurrence-owner'),bindings=require('trigger_authority').snapshot(event or {}),restrictions=invoke.durable_restrictions(authority(id,record))})})
    sql('UPDATE workflow_triggers SET last_at=? WHERE id=?',{opts.now and opts.now() or os.time(),id})
    return true
   end)
  end)
 end
 function r:enqueue(id,occ,origin,event)
  local claimed,why=require('trigger_authority').execute(event or {},function() return self:claim(id,occ,origin,event) end)
  if not claimed then return claimed,why end
  local job={id=id,occurrence=occ,source='workflow:'..origin}
  if event then require('trigger_authority').propagate(event,job)end
  queued[job]={id=id,occurrence=occ}
  if opts.enqueue then opts.enqueue(job) else bog.events.emit('serve:workflow',job)end
  return job
 end
 function r:execute(job)
  return protect(function()
   local identity=assert(queued[job],'trigger_queue_identity_invalid');queued[job]=nil
   return require('trigger_authority').execute(job,function()
    local id,occ=identity.id,identity.occurrence;local record=assert(get(id),'trigger_missing')
    local previous=rows('SELECT * FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1]
    assert(previous and previous.status=='claimed','occurrence_not_claimed')
    if record.enabled~=1 then set_status(id,occ,'cancelled',nil,{reason='paused_before_dispatch'});return nil,{code='trigger_paused'}end
    -- Transition under write lock prevents a second process from dispatching.
    tx(function()
     local current=rows('SELECT status FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1]
     assert(current.status=='claimed','occurrence_not_claimed')
     set_status(id,occ,'dispatching',nil,json.decode(previous.body))
    end)
    local b=assert(host[id],'trigger_binding_unavailable')
    local ok,handle,why=pcall(function()
     local saved=json.decode(previous.body);local floor=saved.restrictions
     local a=invoke.live_context(function() return invoke.restrict_durable(authority(id,get(id)),floor) end,invoke.restrict_durable(authority(id,record),floor))
     a=require('trigger_authority').restore(saved.bindings,a)
     return b.registry:start(record.config.workflow,{authority=a,context=b.context,scope=record.config.project,
      run_id='trigger:'..#id..':'..id..':'..occ,defer=true,execution_profile=record.config.execution_profile,
      source_revisions={trigger=id..':'..occ..':'..json.decode(previous.body).origin},
      admit=function()
       local fresh=get(id)
       if not fresh or fresh.enabled~=1 or not host[id] then return nil,{code='trigger_cancelled'}end
       local row=rows('SELECT status FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1]
       return row and row.status~='cancelled' and row.status~='cancel_requested', {code='trigger_cancelled'}
      end})
    end)
    if not ok or not handle then
     set_status(id,occ,'denied',nil,{error=not ok and tostring(handle) or why});return nil,not ok and {code=tostring(handle)} or why
    end
    local snap=handle:snapshot();handles[id..'\0'..occ]=handle
    set_status(id,occ,'dispatching',snap.id,{origin=json.decode(previous.body).origin,version=snap.workflow.version,learning=snap.learning})
    snap=handle:resume()
    set_status(id,occ,snap.status,snap.id,{origin=json.decode(previous.body).origin,version=snap.workflow.version,error=snap.error})
    return handle
   end)
  end)
 end
 function r:run(id,origin,occ,event)
  occ=occ or require('evidence').id('occasion')
  local claimed,why=require('trigger_authority').execute(event or {},function() return self:claim(id,occ,origin or 'named',event) end)
  if not claimed then return nil,why end
  local job={};queued[job]={id=id,occurrence=occ}
  return self:execute(job)
 end
 function r:cancel(id,occ)
  return protect(function()
   local row=rows('SELECT * FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1];assert(row,'occurrence_missing')
   if not ({claimed=true,dispatching=true,suspended=true,recovering=true,cancel_requested=true})[row.status] then
    return false,{code='occurrence_terminal_or_uncertain'}
   end
   local handle=handles[id..'\0'..occ]
   local snapshot=handle and handle:cancel()
   if row.status=='claimed' or snapshot then
    set_status(id,occ,snapshot and snapshot.status or 'cancelled',row.run_id,{reason='host_cancelled',effects_incomplete=snapshot and snapshot.effects_incomplete})
   else set_status(id,occ,'cancel_requested',row.run_id,{reason='host_cancelled'})end
   return true
  end)
 end
 -- Recovery is explicit. The host supervisor must prove the previous executor
 -- quiescent; elapsed time is never such proof. Dispatch without a durable run
 -- reference remains uncertain and cannot be automatically repeated.
 function r:recover(id,occ,quiescent)
  return protect(function()
   local record=assert(get(id),'trigger_missing');assert(record.enabled==1,'trigger_paused')
   local row=rows('SELECT * FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1]
   assert(row,'occurrence_missing');assert(host[id],'trigger_binding_unavailable')
   if row.status=='claimed' then
    local job={id=id,occurrence=occ,source='workflow:recovery'};queued[job]={id=id,occurrence=occ}
    return self:execute(job)
   end
   assert(row.run_id,'dispatch_uncertain_without_run')
   assert(row.status=='dispatching' or row.status=='suspended' or row.status=='uncertain' or row.status=='recovering','occurrence_not_recoverable')
   assert(type(quiescent)=='function','executor_quiescence_required')
   local b=host[id]
   assert(type(b.registry.resume)=='function','registry_recovery_unavailable')
   local saved=json.decode(row.body)
   local monitor_ticket,why=b.registry:recovery_ticket(record.config.workflow,saved.learning and saved.learning.version,'trigger:'..#id..':'..id..':'..occ)
   assert(monitor_ticket,why and why.code or 'registry_recovery_unavailable')
   local ticket={owner=saved.owner,run_id=row.run_id,id=id,occurrence=occ,monitor=monitor_ticket}
   local stopped,proof=quiescent(id,occ,row.run_id,copy(ticket))
   assert(stopped==true and type(proof)=='table' and proof.owner==ticket.owner and proof.monitor_owner==monitor_ticket.owner and type(proof.ref)=='string' and proof.ref~='','executor_quiescence_required')
   local function current()
    local latest=assert(get(id),'trigger_missing');assert(latest.enabled==1,'trigger_paused')
    local status=rows('SELECT status FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1]
    assert(status and status.status~='cancelled' and status.status~='cancel_requested','trigger_cancelled')
    return invoke.restrict_durable(authority(id,latest),json.decode(row.body).restrictions)
   end
   local a=require('trigger_authority').restore(saved.bindings,invoke.live_context(current,current()))
   tx(function()
    local current_row=rows('SELECT status,body FROM workflow_occurrences WHERE trigger_id=? AND occurrence=?',{id,occ})[1]
    assert(current_row.status==row.status and json.decode(current_row.body).owner==ticket.owner,'recovery_owner_exists')
    set_status(id,occ,'recovering',row.run_id,{proof=proof,owner=require('evidence').id('recovery-owner')})
   end)
   local handle,why=b.registry:resume(record.config.workflow,row.run_id,{authority=a,run_id='trigger:'..#id..':'..id..':'..occ,
    learning=json.decode(row.body).learning,execution_profile=record.config.execution_profile,recovery_proof={owner=proof.monitor_owner,ref=proof.ref,project=record.config.project,id=record.config.workflow,version=saved.learning and saved.learning.version,run_id='trigger:'..#id..':'..id..':'..occ}})
   if not handle then set_status(id,occ,'uncertain',row.run_id,{error=why,proof=proof});return nil,why end
   handles[id..'\0'..occ]=handle
   local snap=handle:snapshot();set_status(id,occ,snap.status,snap.id,{recovered=true,proof=proof,error=snap.error})
   return handle
  end)
 end
 function r:tick(now)
  now=now or os.time();local count=0
  for _,record in ipairs(rows('SELECT * FROM workflow_triggers WHERE enabled=1 AND next_at<=? ORDER BY id LIMIT 64',{now}))do
   local c=json.decode(record.body);local due=record.next_at
   if host[record.id]then
    local valid,next_at=pcall(function()
     return c.schedule.every and (due+(math.floor((now-due)/c.schedule.every)+1)*c.schedule.every) or next_time(c,now)
    end)
    if not valid then
     c.error=tostring(next_at)
     sql('UPDATE workflow_triggers SET body=?,enabled=0 WHERE id=?',{json.encode(c),record.id})
    else
     -- Competing tickers claim the same physical occurrence, never a new ID.
     if c.misfire=='once' or now-due<60 then
      local job=self:enqueue(record.id,tostring(due),'timer');if job then count=count+1 end
     end
     tx(function()local latest=get(record.id);if latest.next_at==due then sql('UPDATE workflow_triggers SET next_at=? WHERE id=?',{next_at,record.id})end end)
    end
   end
  end
  return count
 end
 return r
end
return M
