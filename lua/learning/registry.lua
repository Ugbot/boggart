-- Privileged host registry. SQL transactions serialize pointers, pins and ledger.
local M={}
local json,identity=require('json'),require('learning.identity')
local function fail(code)error({code=code},0)end
local function must(v,e)if v==nil or v==false then fail(type(e)=='table' and e.code or 'registry_database')end;return v end
local function protect(fn)local ok,a,b=pcall(fn);if ok then return a,b end;return nil,type(a)=='table' and a or {code=tostring(a)}end
local function text(s)return type(s)=='string' and #s>0 and #s<=1024 end
-- Tagged JSON preserves numeric keys, integer/float identity and all float bits.
-- Plain JSON would round evaluator timing evidence and change its report hash.
local function pack(v,seen)
 local t=type(v)
 if t=='nil'then return {'nil'}end
 if t=='string' or t=='boolean'then return {t,v}end
 if t=='number'then
  if v~=v or math.abs(v)==math.huge then fail('invalid_data')end
  return {math.type(v),math.type(v)=='integer' and string.format('%d',v) or string.format('%a',v)}
 end
 if t~='table' or getmetatable(v)then fail('invalid_data')end
 seen=seen or {};if seen[v]then fail('invalid_data')end;seen[v]=true
 local out={'table'};for k,x in pairs(v)do out[#out+1]={pack(k,seen),pack(x,seen)}end
 seen[v]=nil;return out
end
local function unpacked(v)
 if v[1]=='nil'then return nil end
 if v[1]=='integer' or v[1]=='float'then return tonumber(v[2])end
 if v[1]~='table'then return v[2]end
 local out={};for i=2,#v do out[unpacked(v[i][1])]=unpacked(v[i][2])end;return out
end
local function encode(v)return must(json.encode(pack(v)))end
local function decode(v)return unpacked(json.decode(v))end
local function copy(v)return unpacked(pack(v))end
local ranks={auto=1,review=2,off=3}
function M.open(o)
 return protect(function()
  assert(type(o)=='table' and o.db and text(o.project) and type(o.validate)=='function' and type(o.qualification)=='table' and text(o.qualification.id) and text(o.qualification.revision) and type(o.qualification.check)=='function','registry_configuration_required')
  local db=o.db
  must(db:exec([[PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS learning_versions(project TEXT,id TEXT,version TEXT,state TEXT,body TEXT NOT NULL,PRIMARY KEY(project,id,version));
CREATE TABLE IF NOT EXISTS learning_heads(project TEXT,id TEXT,generation INTEGER NOT NULL,version TEXT,previous TEXT,percent INTEGER NOT NULL,PRIMARY KEY(project,id));
CREATE TABLE IF NOT EXISTS learning_controls(project TEXT,id TEXT,mode TEXT NOT NULL,PRIMARY KEY(project,id));
CREATE TABLE IF NOT EXISTS learning_pins(project TEXT,id TEXT,run TEXT,version TEXT NOT NULL,PRIMARY KEY(project,id,run));
CREATE TABLE IF NOT EXISTS learning_audit(sequence INTEGER PRIMARY KEY AUTOINCREMENT,project TEXT,id TEXT,body TEXT NOT NULL);
]]))
  local r={}
  local function rows(sql,args)return must(db:query(sql,args))end
  local function run(sql,args)return must(db:run(sql,args))end
  local function tx(fn)
   must(db:exec('BEGIN IMMEDIATE'));local ok,a,b=pcall(fn)
   if ok then local yes=db:exec('COMMIT');if yes then return a,b end end
   pcall(db.exec,db,'ROLLBACK');if ok then fail('registry_database')end;error(a,0)
  end
  local function get(id,version)
   local row=rows('SELECT state,body FROM learning_versions WHERE project=? AND id=? AND version=?',{o.project,id,version})[1]
   if not row then fail('candidate_missing')end
   local v=decode(row.body);v.state=row.state;return v
  end
  local function head(id)
   return rows('SELECT generation,version,previous,percent FROM learning_heads WHERE project=? AND id=?',{o.project,id})[1] or {generation=0,percent=100}
  end
  local function audit(id,record)
   run('INSERT INTO learning_audit(project,id,body) VALUES(?,?,?)',{o.project,id,encode(record)});return copy(record)
  end
  local function mode(id,requested)
   if requested~=nil and not ranks[requested] then fail('mode_invalid')end
   local selected=requested or 'auto'
   for _,row in ipairs(rows('SELECT mode FROM learning_controls WHERE project=? AND (id=? OR id=?)',{o.project,'',id}))do
    if ranks[row.mode]>ranks[selected] then selected=row.mode end
   end
   return selected
  end
  local function validate(v,phase,ctx)
   if not v.report then fail('evaluation_missing')end
   require('learning.promote').check(v.candidate,v.report)
   if v.binding~=identity.hash({revisions=o.revisions or {},qualification={id=o.qualification.id,revision=o.qualification.revision}}) then fail('evaluation_stale')end
   local ok,ref=o.validate(copy(v.candidate),copy(v.report),phase,ctx)
   if ok~=true or not text(ref)then fail('authority_or_precondition_denied')end
   local qualified,evidence=o.qualification.check(copy(v.candidate),copy(v.report),phase,ctx)
   if qualified~=true or not text(evidence)then fail('runtime_unqualified')end
   return {authority=ref,runtime=evidence,qualification={id=o.qualification.id,revision=o.qualification.revision},evaluation_runtime=v.report.coverage.runtime}
  end
  function r:register(id,version,candidate)
   return protect(function()return tx(function()
    if not text(id) or not text(version) then fail('candidate_invalid')end
    local c=copy(candidate)
    if type(c.source)~='string' or c.source_hash~=require('workflow').hash(c.source) or not c.manifest then fail('candidate_invalid')end
    if #rows('SELECT version FROM learning_versions WHERE project=? AND id=? AND version=?',{o.project,id,version})>0 then fail('version_exists')end
    local v={id=id,version=version,candidate=c,contract_hash=identity.hash(c)}
    run('INSERT INTO learning_versions VALUES(?,?,?,?,?)',{o.project,id,version,'candidate',encode(v)})
    audit(id,{action='register',version=version,contract_hash=v.contract_hash});v.state='candidate';return v
   end)end)
  end
  function r:evaluate(id,version,dataset,policy)
   return protect(function()
    local v=get(id,version)
    if v.state~='candidate' then fail('evaluation_immutable')end
    local report=require('learning.evaluate').run(v.candidate,dataset,policy)
    return tx(function()
     v=get(id,version);if v.state~='candidate' then fail('evaluation_immutable')end
     v.report=report;v.report_hash=identity.hash(report)
     v.binding=identity.hash({revisions=o.revisions or {},qualification={id=o.qualification.id,revision=o.qualification.revision}})
     run('UPDATE learning_versions SET state=?,body=? WHERE project=? AND id=? AND version=?',{'evaluated',encode(v),o.project,id,version})
     audit(id,{action='evaluate',version=version,report_hash=v.report_hash,eligible=report.eligibility});return report
    end)
   end)
  end
  function r:get(id,version)return protect(function()return get(id,version)end)end
  function r:head(id)return protect(function()return head(id)end)end
  function r:control(id,value)
   return protect(function()return tx(function()
    id=id or '';if not ranks[value]then fail('mode_invalid')end
    run('INSERT INTO learning_controls VALUES(?,?,?) ON CONFLICT(project,id) DO UPDATE SET mode=excluded.mode',{o.project,id,value})
    return audit(id,{action='control',mode=value})
   end)end)
  end
  local function switch(id,version,report,opts,rollback,rollout)
   opts=opts or {};local v=get(id,version);local h=head(id)
   if opts.expected_generation==nil or opts.expected_generation~=h.generation then
    local result=audit(id,{action='conflict',version=version,generation=h.generation});return nil,{code='activation_conflict',record=result}
   end
   if v.state=='disabled' or v.state=='quarantined' then fail('version_blocked')end
   if not report or identity.hash(report)~=v.report_hash then fail('report_not_registered')end
   local checks=validate(v,rollback and 'rollback' or 'activate',opts.context)
   local selected=mode(id,opts.mode)
   if selected=='off' then return audit(id,{action='off',version=version,generation=h.generation})end
   if selected=='review' and not (opts.approval and type(o.approve)=='function' and o.approve(id,version,copy(report),opts.approval)==true) then
    return audit(id,{action='queued',version=version,generation=h.generation,report_hash=v.report_hash})
   end
   local percent=opts.percent or 100
   if type(percent)~='number' or percent%1~=0 or percent<1 or percent>100 or percent<100 and not h.version then fail('rollout_invalid')end
   if h.version==version and not rollout then fail('already_active')end
   local previous=rollout and h.previous or h.version
   if h.version then run("UPDATE learning_versions SET state=? WHERE project=? AND id=? AND version=? AND state='active'",{'evaluated',o.project,id,h.version})end
   run('UPDATE learning_versions SET state=? WHERE project=? AND id=? AND version=?',{'active',o.project,id,version})
   run('INSERT INTO learning_heads VALUES(?,?,?,?,?,?) ON CONFLICT(project,id) DO UPDATE SET generation=excluded.generation,version=excluded.version,previous=excluded.previous,percent=excluded.percent',{o.project,id,h.generation+1,version,previous or "",percent})
   return audit(id,{action=rollout and 'rollout' or rollback and 'rollback' or 'activate',version=version,previous=previous,generation=h.generation+1,percent=percent,report_hash=v.report_hash,checks=checks})
  end
  local function admission(id,fn)
   local value,why=protect(function()return tx(fn)end)
   if not value and why.code~='activation_conflict' then
    -- A rejected transaction made no pointer changes. Record the refusal separately;
    -- database failure itself may prevent recording, and still refuses admission.
    pcall(function()tx(function()audit(id,{action='rejected',reason=why.code})end)end)
   end
   return value,why
  end
  function r:activate(id,version,report,opts)
   if type(opts)=='string'then opts={mode=opts}end
   return admission(id,function()return switch(id,version,report,opts,false)end)
  end
  function r:rollback(id,target,opts)
   return admission(id,function()local v=get(id,target);return switch(id,target,v.report,opts,true)end)
  end
  function r:rollout(id,percent,opts)
   return admission(id,function()
    local h=head(id);if not h.version then fail('active_missing')end
    local settings={};for k,v in pairs(opts or {})do settings[k]=v end;settings.percent=percent
    local v=get(id,h.version);return switch(id,h.version,v.report,settings,false,true)
   end)
  end
  function r:set_state(id,version,state,reason)
   return protect(function()return tx(function()
    if (state~='disabled' and state~='quarantined') or not text(reason)then fail('state_invalid')end
    get(id,version);run('UPDATE learning_versions SET state=? WHERE project=? AND id=? AND version=?',{state,o.project,id,version})
    return audit(id,{action=state,version=version,reason=reason})
   end)end)
  end
  function r:resolve(id,ctx)
   return protect(function()return tx(function()
    if type(ctx)~='table' or not text(ctx.run_id)then fail('run_id_required')end
    local pin=rows('SELECT version FROM learning_pins WHERE project=? AND id=? AND run=?',{o.project,id,ctx.run_id})[1]
    local version=pin and pin.version
    if not version then
     local h=head(id);version=h.version
     if version and h.percent<100 then
      local bucket=tonumber(require('workflow').hash(o.project..'/'..id..'/'..ctx.run_id):sub(1,8),16)%100
      if bucket>=h.percent then version=h.previous end
     end
    end
    if not version then fail('active_missing')end
    local v=get(id,version)
    if v.state=='disabled' or v.state=='quarantined' then fail('version_blocked')end
    validate(v,'resolve',ctx)
    if not pin then run('INSERT INTO learning_pins VALUES(?,?,?,?)',{o.project,id,ctx.run_id,version});audit(id,{action='pin',version=version,run_id=ctx.run_id})end
    return {id=id,version=version,source_hash=v.candidate.source_hash,contract_hash=v.contract_hash,run_id=ctx.run_id}
   end)end)
  end
  function r:select(id,options)
   return protect(function()
    options=options or {};local ctx={run_id=options.run_id or require('evidence').id('learning-run'),options=options}
    local pin,why=self:resolve(id,ctx);if not pin then error(why,0)end
    if options.version and options.version~=pin.version then fail('version_override_denied')end
    local v=get(id,pin.version)
    local function guard()
     return protect(function()
      local fresh=get(id,pin.version)
      if fresh.state=='disabled' or fresh.state=='quarantined'then fail('version_blocked')end
      validate(fresh,'effect',ctx);return true
     end)
    end
    return {id=id,version=pin.version,source=v.candidate.source,source_hash=v.candidate.source_hash,capabilities=copy(v.candidate.manifest.capabilities),metadata={learning_contract=v.contract_hash}},guard
   end)
  end
  function r:start(id,options)
   return protect(function()
    local supplied=options or {};options={};for k,v in pairs(supplied)do options[k]=v end
    options.run_id=options.run_id or require('evidence').id('learning-run')
    if not options.authority then fail('current_authority_required')end
    if options.scope and options.scope~=o.project then fail('project_scope_mismatch')end
    local definition,guard=self:select(id,options);if not definition then error(guard,0)end
    local workflow=require('workflow')
    definition.id='learning:'..#o.project..':'..o.project..':'..id
    definition.inactive=true
    local existing=workflow.resolve(definition.id,definition.version)
    if existing then
     if existing.source_hash~=definition.source_hash or identity.hash(existing.capabilities)~=identity.hash(definition.capabilities) or not existing.metadata or existing.metadata.learning_contract~=definition.metadata.learning_contract then fail('runtime_version_conflict')end
    else local ok,why=workflow.register(definition);if not ok then error(why,0)end end
    local opts={};for k,v in pairs(options)do opts[k]=v end
    opts.version=definition.version;opts.scope=o.project
    local inherited_admit=options.admit
    opts.admit=function()
     local ok,why=guard();if ok~=true then return nil,why end
     if inherited_admit then return inherited_admit()end
     return true
    end
    opts.learning={project=o.project,id=id,version=definition.version,run_id=options.run_id}
    local handle,why=workflow.start(definition.id,opts);if not handle then error(why,0)end;return handle
   end)
  end
  function r:audit(id)return protect(function()local out={};for _,row in ipairs(rows('SELECT sequence,body FROM learning_audit WHERE project=? AND id=? ORDER BY sequence',{o.project,id}))do local v=decode(row.body);v.sequence=row.sequence;out[#out+1]=v end;return out end)end
  return r
 end)
end
return M
