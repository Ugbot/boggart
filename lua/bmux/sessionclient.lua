-- Explicit checkpoint transfer. This client never starts or resumes processes.
local Native=require 'terminal.client';local Codec=require 'bmux.checkpoint'
local M={};local Client={};Client.__index=Client
local function problem(message)return {kind='session',message=message}end
local function identifier(s)return type(s)=='string'and #s>0 and #s<=128 and s:match('^[%w_-]+$')end
function M.new(opts)
  assert(identifier(opts.host_id),'known layout host required')
  return setmetatable({transport=Native.new(opts),host_id=opts.host_id},Client)
end
function Client:_request(method,path,body,validate,callback)
  assert(type(callback)=='function','callback required')
  if self.closed or self.busy or method=='POST'and self.uncertain then
    callback(problem('Session transfer unavailable; observe or rejoin after an uncertain import'));return
  end
  self.busy=true
  return self.transport:request(method,path,body,function(why,value,status)
    if self.closed then return end
    self.busy=false
    if not why then value,why=validate(value)end
    -- No replay, including after a malformed/lost success acknowledgement.
    if method=='POST'and why and (not status or status>=500 or why.kind~='http')then self.uncertain=true end
    if why and why.response and type(why.response.error)=='string'then why.message=why.response.error:sub(1,512)end
    callback(why,value)
  end)
end
function Client:export(callback)
  return self:_request('GET','/layout/checkpoint',nil,function(value)
    local doc,why=Codec.validate(value);if not doc then return nil,why end
    if doc.layout.host_id~=self.host_id then return nil,problem('Layout server changed; join it again explicitly')end
    return Codec.encode(doc)
  end,callback)
end
function Client:status(callback)
  return self:_request('GET','/layout/session',nil,function(value)
    if type(value)~='table'or value.host_id~=self.host_id or type(value.persistent)~='boolean'then
      return nil,problem('Invalid or changed session status host')
    end
    local keys={host_id=true,persistent=true}
    if value.persistent then
      if type(value.name)~='string'or #value.name<1 or #value.name>4096 or not utf8.len(value.name)
        or value.name:find('[%z\1-\31\127]')or type(value.blocked)~='boolean'or type(value.dirty)~='boolean'
        or type(value.restored)~='boolean'or type(value.writes)~='number'or value.writes%1~=0
        or value.writes<0 or value.writes>9007199254740991
        or value.error~=nil and(type(value.error)~='string'or #value.error>512)then
        return nil,problem('Invalid session persistence status')
      end
      for _,k in ipairs{'name','blocked','dirty','restored','writes','error'}do keys[k]=true end
    end
    local out={};for k,v in pairs(value)do if not keys[k]then return nil,problem('Unknown session status field')end;out[k]=v end
    return out
  end,callback)
end
function Client:import(name,raw,callback)
  assert(type(callback)=='function','callback required')
  if not identifier(name)then callback(problem('Import name requires 1–128 ASCII letters, digits, underscores or hyphens'));return end
  local doc,why=Codec.import(raw);if not doc then callback(why);return end
  local text;text,why=Codec.encode(doc);if not text then callback(why);return end
  return self:_request('POST','/layout/checkpoints/'..self.host_id..'/'..name,text,function(value)
    if type(value)~='table'or value.name~=name or value.inactive~=true or value.restart_required~=true then
      return nil,problem('Invalid inactive-session import acknowledgement')
    end
    for k in pairs(value)do if k~='name'and k~='inactive'and k~='restart_required'then
      return nil,problem('Unknown import acknowledgement field')
    end end
    return value
  end,callback)
end
function Client:saved(name,callback)
  assert(type(callback)=='function','callback required')
  if not identifier(name)then callback(problem('Invalid saved session name'));return end
  return self:_request('GET','/layout/checkpoints/'..self.host_id..'/'..name,nil,function(value)return Codec.encode(value)end,callback)
end
function Client:close()
  if self.closed then return end;self.closed=true;self.transport:close()
end
return M
