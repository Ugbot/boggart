-- One named SQLite owner, coalesced native changes and a final pre-release save.
local uv=require 'uv';local json=require 'json';local Codec=require 'bmux.checkpoint'
local Capture=require 'bmux.capture';local Restore=require 'bmux.restore'
local M={};local Journal={};Journal.__index=Journal
function Journal:_fail(why)
  self.blocked=true;self.error=tostring(why):sub(1,512);return nil,self.error
end
function Journal:_call(method,...)
  local ok,value,why=pcall(self.store[method],...)
  if not ok then return self:_fail(value)end
  if value==nil and why then return self:_fail(why)end
  return value
end
function Journal:_claim()
  local previous=self:_call('kv_get',self.owner_key);if self.blocked then return end
  if previous then
    if #previous>1024 then return self:_fail('Saved session owner record is invalid; explicit recovery required')end
    local ok,owner=pcall(json.decode,previous)
    if not ok or type(owner)~='table'or type(owner.pid)~='number'or owner.pid%1~=0 or owner.pid<1 or owner.pid>2147483647 then
      return self:_fail('Saved session owner record is invalid; explicit recovery required')
    end
    local alive,why=uv.kill(owner.pid,0)
    if alive or not tostring(why):find('ESRCH',1,true)then return self:_fail('Saved session is owned by a live process')end
  end
  self.owner=json.encode{v=1,pid=uv.os_getpid(),token=serve.token(16)}
  local claimed=self:_call('kv_compare_set',self.owner_key,previous,self.owner)
  if self.blocked then return end
  if not claimed then return self:_fail('Saved session owner changed; retry startup explicitly')end
  self.claimed=true
end
function Journal:changed()
  if self.closed or self.blocked then return end
  self.dirty=true
  if not self.timer then
    local timer=uv.new_timer();self.timer=timer;timer:unref()
    timer:start(250,0,function()
      if self.timer~=timer then return end
      self.timer=nil;timer:close();self:flush()
    end)
  end
end
function Journal:observe(entry)
  if entry.term and not entry.closed and not self.observed[entry.id]then
    local ok,why=self.control.terminals:observe(entry,self.life_key,function(e,event)
      if event=='released'then self.observed[e.id]=nil else Capture.metadata(e)end
      self:changed()
    end)
    if not ok then self:_fail(why.message);return end
    self.observed[entry.id]=entry
  end
  self:changed()
end
function Journal:flush()
  if self.closed or self.blocked or not self.claimed then return nil,self.error end
  local owner=self:_call('kv_get',self.owner_key);if self.blocked then return nil,self.error end
  if owner~=self.owner then return self:_fail('Saved session ownership changed; checkpoint withheld')end
  local ok,doc,why=pcall(Capture.collect,self.control,self.cache)
  if not ok then return self:_fail(doc)end
  if not doc then return self:_fail(why.message)end
  local text; text,why=Codec.encode(doc);if not text then return self:_fail(why.message)end
  if text~=self.last then
    local written=self:_call('kv_compare_set',self.key,self.last,text)
    if self.blocked then return nil,self.error end
    if not written then return self:_fail('Saved checkpoint changed; local state was not overwritten')end
    self.last=text;self.writes=self.writes+1
  end
  self.dirty=false;return true
end
function Journal:status()
  return {name=self.name,blocked=self.blocked or false,error=self.error,dirty=self.dirty or false,
    writes=self.writes,restored=self.restored or false}
end
function M.new(control,name,store)
  assert(type(name)=='string'and #name>0 and #name<=4096 and utf8.len(name)and not name:find('[%z\1-\31\127]'),'invalid saved session name')
  local self=setmetatable({control=control,name=name,store=store or bog.store,key='bmux.session.v1:'..name,
    owner_key='bmux.owner.v1:'..name,life_key='journal:'..serve.token(8),cache={},observed={},writes=0},Journal)
  if not self.store.is_open()then self:_fail('Checkpoint store is not open');return self end
  self:_claim();if self.blocked then return self end
  self.last=self:_call('kv_get',self.key);if self.blocked then return self end
  if self.last then
    local doc,why=Codec.decode(self.last)
    if not doc then self:_fail(why.message);return self end
    local result;result,why=Restore.apply(control,doc)
    if not result then self:_fail(why.message);return self end
    self.restored=true
  end
  self.layout=control.layout;self.old_changed=self.layout.changed
  self.changed_layout=function(snapshot)self:changed();if self.old_changed then self.old_changed(snapshot)end end
  self.layout.changed=self.changed_layout
  control.terminals:watch(self.life_key,function(entry,event)
    if event=='opened'then self:observe(entry)else self:changed()end
  end)
  self.fleet_key=self.life_key
  control.fleet.registry:watch(self.fleet_key,function()self:changed()end)
  for _,id in ipairs(control.terminals.order)do self:observe(control.terminals.entries[id])end
  self:changed();return self
end
function Journal:close()
  if self.closed then return end
  if not self.blocked then self:flush()end
  self.closed=true
  if self.timer then self.timer:stop();self.timer:close();self.timer=nil end
  self.control.terminals:watch(self.life_key,nil)
  if self.fleet_key then self.control.fleet.registry:watch(self.fleet_key,nil)end
  for id,entry in pairs(self.observed)do
    if self.control.terminals.entries[id]==entry then self.control.terminals:observe(entry,self.life_key,nil)end
  end
  if self.layout and self.layout.changed==self.changed_layout then self.layout.changed=self.old_changed end
  if self.claimed then self:_call('kv_compare_set',self.owner_key,self.owner,nil);self.claimed=false end
end
return M
