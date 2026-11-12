-- Explicit checkpoint transfer. This client never starts or resumes processes.
local Native=require 'terminal.client';local Codec=require 'bmux.checkpoint'
local M={};local Client={};Client.__index=Client
local function problem(message)return {kind='session',message=message}end
local function identifier(s)return type(s)=='string'and #s>0 and #s<=128 and s:match('^[%w_-]+$')end
local function integer(n,limit)return type(n)=='number'and n%1==0 and n>=0 and n<=(limit or 9007199254740991)end
local function plain(s,limit)return type(s)=='string'and #s>0 and #s<=limit and utf8.len(s)and not s:find('[%z\1-\31\127]')end
local function fields(value,keys)
  if type(value)~='table'or getmetatable(value)then return false end
  for k in pairs(value)do if not keys[k]then return false end end;return true
end
local function archive(value)
  if not fields(value,{id=true,path=true,bytes=true,present=true})or not identifier(value.id)
    or not plain(value.path,4096)or value.path:sub(1,1)~='/'or not integer(value.bytes,64*1024*1024)
    or type(value.present)~='boolean'or not value.present and value.bytes~=0 then return nil,problem('Invalid recovery archive')end
  return {id=value.id,path=value.path,bytes=value.bytes,present=value.present}
end
local function same(a,b)return a.id==b.id and a.path==b.path and a.bytes==b.bytes and a.present==b.present end
local function status(value,host)
  if type(value)~='table'or value.host_id~=host or type(value.persistent)~='boolean'then return nil,problem('Invalid or changed session status host')end
  local keys={host_id=true,persistent=true};local saved
  if value.persistent then
    if not plain(value.name,4096)or type(value.blocked)~='boolean'or type(value.dirty)~='boolean'
      or type(value.restored)~='boolean'or not integer(value.writes)
      or value.error~=nil and(type(value.error)~='string'or #value.error>512)then return nil,problem('Invalid session persistence status')end
    for _,k in ipairs{'name','blocked','dirty','restored','writes','error','last_recovery'}do keys[k]=true end
    if value.last_recovery~=nil then local why;saved,why=archive(value.last_recovery);if not saved then return nil,why end end
  end
  if not fields(value,keys)then return nil,problem('Unknown session status field')end
  local out={};for k,v in pairs(value)do out[k]=v end;out.last_recovery=saved;return out
end
local function preview(value,host)
  if not fields(value,{host_id=true,revision=true,name=true,recovery_id=true,archive=true,workspaces=true,terminals=true,agents=true})
    or value.host_id~=host or not integer(value.revision)or not plain(value.name,4096)or not identifier(value.recovery_id)
    or not integer(value.workspaces,16)or not integer(value.terminals,4096)or not integer(value.agents,4096)then
    return nil,problem('Invalid or changed recovery preview')
  end
  local saved,why=archive(value.archive);if not saved then return nil,why end
  if saved.id~=value.recovery_id then return nil,problem('Recovery archive identity mismatch')end
  return {host_id=host,revision=value.revision,name=value.name,recovery_id=value.recovery_id,archive=saved,
    workspaces=value.workspaces,terminals=value.terminals,agents=value.agents}
end
function M.new(opts)
  assert(identifier(opts.host_id),'known layout host required')
  return setmetatable({transport=Native.new(opts),host_id=opts.host_id},Client)
end
function Client:_request(method,path,body,validate,callback)
  assert(type(callback)=='function','callback required')
  if self.closed or self.busy or method=='POST'and self.uncertain then
    callback(problem('Session change unavailable; observe or rejoin after an uncertain request'));return
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
  return self:_request('GET','/layout/session',nil,function(value)return status(value,self.host_id)end,callback)
end
function Client:recovery_preview(callback)
  return self:_request('GET','/layout/session/recovery',nil,function(value)return preview(value,self.host_id)end,callback)
end
function Client:recovery_status(callback)
  return self:_request('GET','/layout/session/recovery/status',nil,function(value)return status(value,self.host_id)end,callback)
end
function Client:recover(input,callback)
  assert(type(callback)=='function','callback required')
  local p,why=preview(input,self.host_id);if not p then callback(why);return end
  return self:_request('POST','/layout/session/recover',{host_id=p.host_id,revision=p.revision,recovery_id=p.recovery_id},function(value)
    if not fields(value,{recovered=true,host_id=true,revision=true,archive=true,status=true})or value.recovered~=true
      or value.host_id~=self.host_id or value.revision~=p.revision then return nil,problem('Invalid recovery acknowledgement')end
    local saved,e=archive(value.archive);if not saved then return nil,e end
    local info;info,e=status(value.status,self.host_id);if not info then return nil,e end
    if not same(saved,p.archive)or not info.persistent or info.blocked or info.name~=p.name
      or not info.last_recovery or not same(saved,info.last_recovery)then return nil,problem('Recovery acknowledgement changed its preview')end
    return {recovered=true,host_id=self.host_id,revision=p.revision,archive=saved,status=info}
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
