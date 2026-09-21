-- Injected values and trusted Lua providers. One resolver belongs to one run.
local M = {}
local invoke, capability, events = require('invoke'), require('capability'), require('events')
local serial = 0
local errors = setmetatable({}, {__mode='k'})
local function copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}; for k,x in pairs(v) do out[k] = copy(x) end; return out
end
local function failure(code, message, path)
  local e = {code=code, message=message, retryable=false, path=path}
  errors[e] = true; return e
end
-- Deliberately not JSON: unsupported/opaque objects and closures cannot acquire
-- accidental identical keys. Only acyclic, metatable-free data is canonicalized.
local function stable(v, seen)
  local t = type(v)
  if t == 'nil' then return 'z' end
  if t == 'boolean' then return v and 'b1' or 'b0' end
  if t == 'string' then return 's' .. #v .. ':' .. v end
  if t == 'number' then
    if v ~= v or math.abs(v) == math.huge then return nil end
    if math.type(v)=='integer' then return 'i' .. tostring(v) end
    return 'n' .. string.format('%.17g', v)
  end
  if t ~= 'table' or getmetatable(v) ~= nil then return nil end
  seen = seen or {}; if seen[v] then return nil end; seen[v] = true
  local parts = {}
  for k,x in pairs(v) do
    if type(k) ~= 'string' and type(k) ~= 'number' and type(k) ~= 'boolean' then seen[v]=nil; return nil end
    local a,b = stable(k,seen),stable(x,seen)
    if not a or not b then seen[v]=nil; return nil end
    parts[#parts+1] = #a .. ':' .. a .. #b .. ':' .. b
  end
  seen[v] = nil; table.sort(parts); return 't' .. table.concat(parts, ';') .. 'e'
end
local function revision(v)
  if type(v) == 'string' or type(v) == 'number' and v == v and math.abs(v) < math.huge then return v end
end

function M.new(injected, defaults, authority, options)
  injected, defaults, options = injected or {}, defaults or {}, options or {}
  assert(type(injected)=='table' and type(defaults)=='table', 'context maps must be tables')
  -- Validate without examining or modifying the opaque handle.
  invoke.with_context(authority, function() end)
  local pins = {}
  for id,version in pairs(options.capabilities or {}) do
    assert(type(id)=='string' and type(version)=='string' and version~='', 'exact capability pins required')
    pins[id] = version
  end
  local sources = {}
  assert(options.source_revisions==nil or type(options.source_revisions)=='table', 'source_revisions must be a table')
  for k,v in pairs(options.source_revisions or {}) do
    assert(type(k)=='string' and k~='' and revision(v)~=nil, 'source revisions require context keys and finite number or string labels')
    sources[k]=v
  end
  local run_id = revision(options.run_id)
  assert(options.run_id==nil or run_id~=nil, 'run_id must be a finite number or string')
  local stacks = setmetatable({}, {__mode='k'})
  local cache = {}
  local host = {}
  local identities = setmetatable({}, {__mode='k'})
  local function identity(v)
    if not identities[v] then serial=serial+1; identities[v]=serial end
    return identities[v]
  end
  local generation = {}
  local epoch = 0
  local function refresh()
    local now={}
    for _,map in ipairs({injected,defaults}) do
      for k,v in pairs(map) do
        local chosen=rawget(injected,k); if chosen==nil then chosen=rawget(defaults,k) end
        if chosen==v then
          local obj=type(v)=='table' and v or {}
          now[k]={value=v,fn=rawget(obj,'resolve'),revision=rawget(obj,'revision'),cache=rawget(obj,'cache'),cache_key=rawget(obj,'cache_key')}
        end
      end
    end
    local changed=false
    for k,v in pairs(now) do
      local old=generation[k]
      if not old or old.value~=v.value or old.fn~=v.fn or old.revision~=v.revision or old.cache~=v.cache or old.cache_key~=v.cache_key then changed=true end
    end
    for k in pairs(generation) do if not now[k] then changed=true end end
    if changed then cache={}; epoch=epoch+1 end; generation=now
  end
  local resolver = {}
  local function stack()
    local co=coroutine.running(); stacks[co]=stacks[co] or {}; return stacks[co]
  end
  local function emit(stage,p)
    events.emit('context:resolve_' .. stage, copy(p))
  end
  function resolver:call(id,args)
    local version=pins[id]
    if not version then
      return {status='failed', error=failure('capability_unpinned','Capability is not pinned'),
        usage={}, receipt={dispatched=false,id=id}}
    end
    return capability.call(authority,id,version,args)
  end
  function resolver:resolve(key,request)
    if type(key)~='string' or key=='' then return nil,failure('context_invalid','Context key must be a nonempty string') end
    refresh()
    local evaluation_epoch=epoch
    local caller=identity(invoke.current() or host)
    local frames=stack()
    local path={}; for _,frame in ipairs(frames) do path[#path+1]=frame.key end; path[#path+1]=key
    serial=serial+1
    local p={schema_version=1,resolution_id=serial,key=key,run_id=run_id,
      parent_id=frames[#frames] and frames[#frames].id,cache='none',dependencies={},capabilities={}}
    local function finish(value,err)
      p.status=err and (err.code=='context_missing' and 'missing' or 'failed') or 'resolved'
      p.error_code=err and err.code; p.value_type=not err and type(value) or nil
      emit('after',p)
      local parent=frames[#frames]
      if parent then parent.dependencies[#parent.dependencies+1]=copy(p) end
      if err then return nil,err end
      return value,copy(p)
    end
    return invoke.with_context(authority,function()
      -- sethook (including with_context cleanup) resets Lua's hidden remainder.
      -- As in tools.with_count_hook, conservatively charge one parent count
      -- quantum per resolution so repeated fast paths cannot starve its budget.
      local enclosing,_,every=debug.gethook()
      if enclosing and every and every>0 then enclosing('count') end
      for _,frame in ipairs(frames) do
        if frame.key==key then
          return finish(nil,failure('context_cycle','Cyclic context resolution: '..table.concat(path,' -> '),path))
        end
      end
      local selected=rawget(injected,key); p.source='injected'
      if selected==nil then selected=rawget(defaults,key); p.source='default' end
      p.source_revision=sources[key]
      if selected==nil then return finish(nil,failure('context_missing','Context is missing: '..key)) end
      local provider
      if type(selected)=='function' then provider=selected
      elseif type(selected)=='table' then provider=rawget(selected,'resolve') end
      if provider==nil then return finish(selected) end
      if type(provider)~='function' then return finish(nil,failure('context_invalid','Provider resolve must be a function')) end
      local object=type(selected)=='table' and selected or {}
      local lifetime=rawget(object,'cache') or 'none'
      p.provider_revision=revision(rawget(object,'revision'))
      if rawget(object,'revision')~=nil and p.provider_revision==nil then
        return finish(nil,failure('context_invalid','Provider revision must be a finite number or string'))
      end
      if lifetime~='none' and lifetime~='run' and lifetime~='step' then
        return finish(nil,failure('context_invalid','Provider cache must be none, step or run'))
      end
      p.cache_lifetime=lifetime
      local frame={key=key,id=p.resolution_id,dependencies=p.dependencies}
      frames[#frames+1]=frame
      -- All user callbacks, including cache-key derivation, run under authority.
      local entry_hook,entry_mask,entry_count=debug.gethook()
      local hook_failed,hook_error=false,nil
      local function tracked_hook(event,line)
        if hook_failed then error(hook_error,0) end
        local ok,why=pcall(entry_hook,event,line)
        if not ok then hook_failed,hook_error=true,why; error(why,0) end
      end
      local ok,value,err=xpcall(function()
        if entry_hook then debug.sethook(tracked_hook,entry_mask,entry_count) end
        emit('before',p)
        local ctx={}
        function ctx:resolve(child,child_request) return resolver:resolve(child,child_request) end
        function ctx:call(id,args)
          local outcome=resolver:call(id,args)
          p.capabilities[#p.capabilities+1]={id=id,version=pins[id],status=outcome.status,
            invocation_id=outcome.receipt and outcome.receipt.invocation_id,usage=copy(outcome.usage or {})}
          return outcome
        end
        local cache_key,reason
        if lifetime~='none' then
          local step=type(request)=='table' and rawget(request,'step_id')
          local fn=rawget(object,'cache_key')
          if fn~=nil and type(fn)~='function' then return nil,failure('context_invalid','Provider cache_key must be a function') end
          local material=request; if fn then material=fn(ctx,request) end
          if fn and material==nil then cache_key=nil else cache_key=stable(material) end
          if not cache_key then reason='unstable_request'
          elseif lifetime=='step' and (step==nil or not stable(step)) then reason='missing_step'
          else cache_key=stable({authority=caller,request=cache_key,step=lifetime=='step' and step or nil,revision=p.provider_revision,source=p.source_revision}) end
          if reason then cache_key=nil; p.cache='bypass'; p.cache_reason=reason else p.cache='miss' end
        end
        refresh()
        if cache_key and epoch~=evaluation_epoch then cache_key=nil; p.cache='bypass'; p.cache_reason='source_changed' end
        local entries=cache[key]
        if entries and (entries.selected~=selected or entries.provider~=provider) then entries=nil end
        if cache_key and entries and entries.values[cache_key] then
          local hit=entries.values[cache_key]; p.cache='hit'; p.evaluated_resolution_id=hit.id
          p.cached_dependencies=copy(hit.dependencies); p.cached_capabilities=copy(hit.capabilities)
          return hit.value
        end
        local result,why=provider(ctx,request)
        if hook_failed then error(hook_error,0) end
        if result==nil then
          if errors[why] then return nil,why end
          return nil,failure(why~=nil and 'context_provider_error' or 'context_missing',
            why~=nil and 'Context provider returned an error' or 'Context provider returned no value')
        end
        refresh()
        if cache_key and epoch~=evaluation_epoch then cache_key=nil; p.cache='bypass'; p.cache_reason='source_changed' end
        if cache_key then
          entries=entries or {selected=selected,provider=provider,values={}}; cache[key]=entries
          entries.values[cache_key]={value=result,id=p.resolution_id,dependencies=copy(p.dependencies),capabilities=copy(p.capabilities)}
        end
        return result
      end,function(why)
        -- An exhausted hook must not interrupt stack/authority restoration.
        debug.sethook()
        return why
      end)
      debug.sethook()
      frames[#frames]=nil
      debug.sethook(entry_hook,entry_mask,entry_count)
      if hook_failed then error(hook_error,0) end
      if not ok then
        if errors[value] then err=value else err=failure('context_provider_error','Context provider raised an error') end
        value=nil
      end
      return finish(value,err)
    end)
  end
  return resolver
end
return M
