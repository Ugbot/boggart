-- Versioned ordinary Lua workflows. Host registry/handles never enter source environments.
local M = {}
local invoke, context, capability = require('invoke'), require('context'), require('capability')
local tools = require('tools')
local registry, active, serial = {}, {}, 0
local current=setmetatable({}, {__mode='k'})
local function copy(v, seen)
  if type(v)~='table' or getmetatable(v) then return v end
  seen=seen or {}; if seen[v] then return seen[v] end
  local t={}; seen[v]=t; for k,x in pairs(v) do t[k]=copy(x,seen) end; return t
end
function M.current() return copy(current[coroutine.running()]) end
local function err(code) return {code=code,message=code,retryable=false} end
local function text(v) return type(v)=='string' and #v>0 end
-- SHA-256 (FIPS 180-4), operating on the exact supplied source bytes.
local K={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
local function rotr(x,n) return ((x>>n)|(x<<(32-n)))&0xffffffff end
function M.hash(source)
  assert(type(source)=='string','source must be a string')
  local len=#source
  source=source..'\128'..string.rep('\0',(55-len)%64)..string.pack('>I8',len*8)
  local h={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
  for offset=1,#source,64 do
    local w={}
    for i=1,16 do w[i]=string.unpack('>I4',source,offset+(i-1)*4) end
    for i=17,64 do
      local x,y=w[i-15],w[i-2]
      w[i]=(w[i-16]+(rotr(x,7)~rotr(x,18)~(x>>3))+w[i-7]+(rotr(y,17)~rotr(y,19)~(y>>10)))&0xffffffff
    end
    local a,b,c,d,e,f,g,j=table.unpack(h)
    for i=1,64 do
      local t1=(j+(rotr(e,6)~rotr(e,11)~rotr(e,25))+((e&f)~((~e)&g))+K[i]+w[i])&0xffffffff
      local t2=((rotr(a,2)~rotr(a,13)~rotr(a,22))+((a&b)~(a&c)~(b&c)))&0xffffffff
      j,g,f,e,d,c,b,a=g,f,e,(d+t1)&0xffffffff,c,b,a,(t1+t2)&0xffffffff
    end
    for i,v in ipairs({a,b,c,d,e,f,g,j}) do h[i]=(h[i]+v)&0xffffffff end
  end
  local out={};for i,v in ipairs(h) do out[i]=string.format('%08x',v) end
  return table.concat(out)
end
local function identity(d)
  return {id=d.id,version=d.version,source_kind=d.source and 'lua_source' or 'trusted_host',
    source_hash=d.source and M.hash(d.source) or nil,hash_algorithm=d.source and 'sha256' or nil,
    capabilities=copy(d.capabilities),workflows=copy(d.workflows),metadata=copy(d.metadata)}
end
local function bindings(values)
  assert(values==nil or type(values)=='table','context must be a table')
  local result={}
  for key,value in pairs(values or {}) do
    if type(value)=='table' and type(value.resolve)=='function' then
      -- Pin the implementation/configuration; opaque concrete values retain identity.
      local provider={};for k,v in pairs(value) do provider[k]=v end
      result[key]=provider
    else result[key]=value end
  end
  return result
end
function M.register(d)
  if type(d)~='table' or getmetatable(d)~=nil or not text(d.id) or not text(d.version) then return nil,err('workflow_invalid') end
  if registry[d.id] and registry[d.id][d.version] then return nil,err('workflow_version_exists') end
  if d.source~=nil then
    if d.source_hash~=nil and (type(d.source)~='string' or d.source_hash~=M.hash(d.source)) then return nil,err('workflow_source_hash_mismatch') end
    if type(d.source)~='string' or d.run~=nil or d.verify~=nil or d.defaults~=nil then return nil,err('workflow_source_conflict') end
    if not load(d.source,'@workflow:'..d.id..':'..d.version,'t',{}) then return nil,err('workflow_source_invalid') end
  elseif type(d.run)~='function' or (d.verify~=nil and type(d.verify)~='function') then return nil,err('workflow_invalid') end
  for _,field in ipairs({'capabilities','workflows'}) do
    if d[field]~=nil and (type(d[field])~='table' or getmetatable(d[field])~=nil) then return nil,err('workflow_invalid') end
    for k,v in pairs(d[field] or {}) do if not text(k) or not text(v) then return nil,err('workflow_invalid') end end
  end
  local function plain(v,seen)
    if type(v)~='table' then return v end
    seen=seen or {};if seen[v] then return seen[v] end
    local out={};seen[v]=out;for k,x in next,v do out[k]=plain(x,seen) end;return out
  end
  local saved=copy(d);saved.metadata=plain(d.metadata);saved.defaults=bindings(d.defaults);saved.capabilities=saved.capabilities or {};saved.workflows=saved.workflows or {}
  registry[d.id]=registry[d.id] or {};registry[d.id][d.version]=saved
  active[d.id]=active[d.id] or d.version
  return identity(saved)
end
function M.activate(id,version)
  if not (registry[id] and registry[id][version]) then return nil,err('workflow_not_found') end
  active[id]=version;return true
end
function M.resolve(id,version)
  local d=registry[id] and registry[id][version]
  if not d then return nil,err('workflow_not_found') end
  return identity(d)
end
local function segment(s) return #s..':'..s end
function M.start(id, options)
  options=options or {}
  if type(options)~='table' then return nil,err('workflow_invalid') end
  local root=registry[id] and registry[id][options.version or active[id]]
  if not root then return nil,err('workflow_not_found') end
  local definitions, manifest={}, {workflows={},capabilities={},providers={injected={},occurrences={}}}
  local function pin(d)
    local key=segment(d.id)..segment(d.version)
    if definitions[key] then return end
    definitions[key]=d;manifest.workflows[key]=identity(d)
    for cap,version in pairs(d.capabilities) do
      local found=capability.resolve(cap,version)
      if not found then error(err('capability_not_found'),0) end
      manifest.capabilities[segment(cap)..segment(version)]={id=cap,version=version}
    end
    for child,version in pairs(d.workflows) do
      local nested=registry[child] and registry[child][version]
      if not nested then error(err('workflow_dependency_missing'),0) end
      pin(nested)
    end
  end
  local ok,why=pcall(pin,root);if not ok then return nil,why end
  local injected=bindings(options.context)
  local source_revisions=copy(options.source_revisions)
  for key,value in pairs(injected) do
    if type(value)=='function' or type(value)=='table' and type(value.resolve)=='function' then
      manifest.providers.injected[key]={kind='trusted_host',revision=type(value)=='table' and value.revision or nil}
    end
  end
  serial=serial+1
  local state={id='workflow-run:'..serial,workflow=identity(root),manifest=manifest,status='created',
    steps={},invocations={},resolutions={},verified=false}
  local authority=invoke.context({policy=options.policy},options.authority)
  local safe=tools.tool_env().coroutine
  local fatal, cancelled, budget_failed, ticks=nil,false,false,0
  local budget=options.instructions or tools.LIMITS.instructions
  if type(budget)~='number' or budget~=budget or budget<1 or budget==math.huge then return nil,err('workflow_invalid_budget') end
  local function mark(status,e)
    if not fatal or status=='uncertain' then fatal={status=status,error=copy(e or err('workflow_'..status))} end
  end
  local function guard()
    if cancelled then error(err('workflow_cancelled'),0) end
    ticks=ticks+1000
    if ticks>budget then budget_failed=true;error(err('workflow_budget'),0) end
  end
  local execute
  execute=function(d,values,path)
    local thread=coroutine.running();local previous=current[thread]
    current[thread]={run_id=state.id,workflow_id=d.id,version=d.version,step_id=path,attempt=1}
    local spec=d
    if d.source then
      local env=tools.tool_env()
      local function unversioned()
        mark('failed',err('workflow_unversioned_effect'))
        error(err('workflow_unversioned_effect'),0)
      end
      -- Generated tool mediation alone does not pin its mutable legacy registry.
      -- All workflow-source effects must use declared versioned ctx:call adapters.
      for name in pairs(env.sys) do env.sys[name]=unversioned end
      env.tools={call=unversioned,names=unversioned}
      for name in pairs(env.gold.fs) do env.gold.fs[name]=unversioned end
      env.events={notify=unversioned}
      env.os.getenv=unversioned
      spec=assert(load(d.source,'@workflow:'..d.id..':'..d.version,'t',env))()
      if type(spec)=='function' then spec={run=spec} end
      if type(spec)~='table' or type(spec.run)~='function' or (spec.verify~=nil and type(spec.verify)~='function') then error(err('workflow_source_contract'),0) end
    end
    local defaults=bindings(spec.defaults)
    local occurrence={workflow_id=d.id,version=d.version,injected={},defaults={}}
    manifest.providers.occurrences[path]=occurrence
    local function describe_providers(map,out,source_kind,source_hash)
      for key,value in pairs(map) do
        if type(value)=='function' or type(value)=='table' and type(value.resolve)=='function' then
          out[key]={kind=source_kind,revision=type(value)=='table' and value.revision or nil,source_hash=source_hash}
        end
      end
    end
    describe_providers(values,occurrence.injected,'trusted_host')
    local selected_defaults={};for key,value in pairs(defaults) do if values[key]==nil then selected_defaults[key]=value end end
    describe_providers(selected_defaults,occurrence.defaults,d.source and 'lua_source' or 'trusted_host',d.source and M.hash(d.source) or nil)
    local resolver=context.new(values,defaults,authority,{run_id=state.id,
      capabilities=d.capabilities,source_revisions=source_revisions})
    local thread_serial=0
    local frames=setmetatable({}, {__mode='k'})
    local function frame()
      local co=coroutine.running()
      if not frames[co] then thread_serial=thread_serial+1;frames[co]={path=path..'/thread#'..thread_serial,counts={}} end
      return frames[co]
    end
    local ctx={}
    local function alive()
      if state.status~='running' then error(err('workflow_not_running'),0) end
      if cancelled then error(err('workflow_cancelled'),0) end
      if budget_failed then error(err('workflow_budget'),0) end
    end
    function ctx:resolve(key,request,opts)
      alive()
      local req=request
      if req==nil then req={} end
      if type(req)=='table' and getmetatable(req)==nil then
        req=copy(req);req.step_id=frame().path
      end
      local resolution={step_id=frame().path,status='running'}
      state.resolutions[#state.resolutions+1]=resolution
      local value,provenance,failure_provenance=resolver:resolve(key,req)
      local observed=value==nil and failure_provenance or provenance
      resolution.provenance=copy(observed);resolution.error=value==nil and copy(provenance) or nil
      resolution.status=value==nil and 'failed' or 'succeeded'
      local required=not (opts and opts.required==false)
      if value==nil and required then mark('failed',provenance) end
      local function failures(p)
        if not p then return end
        for _,field in ipairs({'capabilities','cached_capabilities'}) do
          for _,call in ipairs(p[field] or {}) do
            if call.status=='uncertain' or required and call.status~='succeeded' then
              mark(call.status,err('workflow_provider_capability_'..call.status))
            end
          end
        end
        for _,field in ipairs({'dependencies','cached_dependencies'}) do
          for _,child in ipairs(p[field] or {}) do failures(child) end
        end
      end
      failures(observed)
      return value,provenance,failure_provenance
    end
    function ctx:call(cap,args,opts)
      alive()
      local record={step_id=frame().path,id=cap,version=d.capabilities[cap],status='running'}
      state.invocations[#state.invocations+1]=record
      local outcome=resolver:call(cap,args)
      record.status=outcome.status;record.receipt=copy(outcome.receipt);record.usage=copy(outcome.usage);record.artifacts=copy(outcome.artifacts);record.error=copy(outcome.error)
      if outcome.status=='uncertain' or outcome.status~='succeeded' and not (opts and opts.required==false) then mark(outcome.status,outcome.error) end
      return outcome
    end
    function ctx:step(site,fn)
      alive()
      if not text(site) or type(fn)~='function' then error(err('workflow_step_invalid'),0) end
      local co=coroutine.running();local parent=frame();local previous_correlation=current[co]
      parent.counts[site]=(parent.counts[site] or 0)+1
      local occurrence=parent.path..'/'..segment(site)..'#'..parent.counts[site]
      local record={id=occurrence,site=site,parent_id=parent.path,status='running',workflow=identity(d)}
      state.steps[#state.steps+1]=record;frames[co]={path=occurrence,counts={}}
      current[co]={run_id=state.id,workflow_id=d.id,version=d.version,step_id=occurrence,attempt=1}
      local packed=table.pack(pcall(fn,ctx))
      frames[co]=parent;current[co]=previous_correlation
      if not packed[1] then record.status='failed';record.error=err('workflow_step_error');mark('failed',record.error);error(record.error,0) end
      record.status=fatal and fatal.status or 'succeeded'
      return table.unpack(packed,2,packed.n)
    end
    function ctx:workflow(child,opts)
      alive();opts=opts or {}
      local version=d.workflows[child]
      local nested=version and definitions[segment(child)..segment(version)]
      if not nested then mark('failed',err('workflow_dependency_unpinned'));error(err('workflow_dependency_unpinned'),0) end
      return self:step(opts.site or ('workflow:'..child),function()
        return execute(nested,opts.context and bindings(opts.context) or values,frame().path..'/'..segment(child)..segment(version))
      end)
    end
    function ctx:yield(...) alive();return coroutine.yield(...) end
    local result,run_error=spec.run(ctx)
    if result==nil and run_error~=nil then mark('failed',err('workflow_returned_error')) end
    alive()
    local verified=false
    if not fatal and spec.verify then
      if spec.verify(ctx,result)~=true then mark('failed',err('workflow_verification_failed')) else verified=true end
    end
    current[thread]=previous
    return result,verified
  end
  local co=safe.create(function()
    return invoke.with_context(authority,function()
      local passed,result,verified=tools.with_count_hook(guard,1000,execute,root,injected,
        segment(root.id)..segment(root.version))
      if budget_failed then error(err('workflow_budget'),0) end
      if not passed then error(err('workflow_runtime_error'),0) end
      return result,verified
    end)
  end)
  local handle={}
  function handle:snapshot() return copy(state) end
  function handle:resume(...)
    if state.status~='created' and state.status~='suspended' then return self:snapshot() end
    state.status='running'
    local result=table.pack(safe.resume(co,...))
    if cancelled then current[co]=nil;return self:snapshot() end
    if not result[1] then
      state.status=fatal and fatal.status or 'failed';state.error=fatal and fatal.error or err(budget_failed and 'workflow_budget' or 'workflow_runtime_error')
    elseif coroutine.status(co)=='dead' then
      state.status=fatal and fatal.status or 'succeeded';state.error=fatal and fatal.error
      state.result=result[2];state.verified=state.status=='succeeded' and result[3]==true
    else state.status='suspended';return self:snapshot(),table.unpack(result,2,result.n) end
    current[co]=nil
    for _,records in ipairs({state.resolutions,state.invocations}) do
      for _,record in ipairs(records) do
        if record.status=='running' then
          record.status='incomplete';state.effects_incomplete=true;state.verified=false
          if state.status=='succeeded' then state.status='uncertain';state.error=err('workflow_incomplete_effect') end
        end
      end
    end
    for _,record in ipairs(state.steps) do if record.status=='running' then record.status=state.status end end
    return self:snapshot()
  end
  function handle:cancel()
    if state.status=='created' or state.status=='suspended' or state.status=='running' then
      cancelled=true;state.status='cancelled';state.error=err('workflow_cancelled');state.verified=false
      for _,record in ipairs(state.steps) do if record.status=='running' then record.status='cancelled' end end
      for _,record in ipairs(state.resolutions) do if record.status=='running' then record.status='incomplete';state.effects_incomplete=true end end
      for _,record in ipairs(state.invocations) do if record.status=='running' then record.status='incomplete';state.effects_incomplete=true end end
    end
    return self:snapshot()
  end
  if options.defer~=true then handle:resume() end
  return handle
end
return M
