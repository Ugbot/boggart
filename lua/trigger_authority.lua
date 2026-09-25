-- Host-only deferred authority. Event data carries no serializable grant.
local M={}
local invoke=require('invoke')
local envelopes=setmetatable({},{__mode='k'})
local bindings={}
function M.register(id,state)
  assert(type(id)=='string' and type(state)=='table')
  if bindings[id] then M.revoke(id) end
  bindings[id]=state
  return id
end
function M.revoke(id)
  local st=bindings[id]
  if st then st.policy_scopes={{id='revoked:'..id,revision=1,capabilities={allow={}}}};st.policy=nil end
end
function M.context(id,restrictions)
  local st=assert(bindings[id],'trigger_authority_unavailable')
  local c=invoke.live_context(function()
    return invoke.context{state=assert(bindings[id],"trigger_authority_unavailable")}
  end,invoke.context{state=st})
  return restrictions and invoke.restrict_durable(c,restrictions) or c
end
function M.available(id)return bindings[id]~=nil end
function M.capture(id)
  return invoke.durable_restrictions(M.context(id))
end
function M.attach(event,id,restrictions)
  envelopes[event]=envelopes[event] or {}
  envelopes[event][#envelopes[event]+1]={id=id,initial=M.context(id),restrictions=restrictions or M.capture(id)}
  return event
end
function M.propagate(source,target)
  local e=envelopes[source]
  if e then
    envelopes[target]=envelopes[target] or {}
    for _,binding in ipairs(e) do envelopes[target][#envelopes[target]+1]=binding end
  end
  return target
end
-- Only host binding identities and restriction floors cross a restart.
function M.snapshot(event)
  local out={}
  for _,e in ipairs(envelopes[event] or {}) do
    out[#out+1]={id=e.id,restrictions=e.restrictions}
  end
  return require('json').decode(require('json').encode(out))
end
function M.restore(saved,initial)
  local authority=initial
  for _,binding in ipairs(saved or {}) do
    authority=invoke.live_context(function() return M.context(binding.id,binding.restrictions) end,authority)
  end
  return authority
end
function M.bound(event)return envelopes[event]~=nil end
function M.execute(event,fn,...)
  local e=envelopes[event]
  if not e then return fn(...) end
  local args=table.pack(...)
  local function enter(i)
    if not e[i] then return fn(table.unpack(args,1,args.n)) end
    return invoke.with_context(invoke.restrict_durable(e[i].initial,e[i].restrictions),function() return enter(i+1) end)
  end
  return enter(1)
end
return M
