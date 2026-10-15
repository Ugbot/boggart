-- One validated layout replica over the existing native private-UDS transport.
local Native=require 'terminal.client'
local Snapshot=require 'bmux.snapshot'
local json=require 'json'
local M={};local Client={};Client.__index=Client
local function problem(message)return {kind='state',message=message} end
local function references(snapshot)
  local out={}
  local function visit(node)
    if node.type=='leaf' then for _,v in ipairs(node.views)do out[v.id]=v end
    else visit(node.a);visit(node.b) end
  end
  for _,w in ipairs(snapshot.workspaces)do for _,s in ipairs(w.surfaces)do visit(s.tree) end end
  return out
end
function M.new(opts)
  return setmetatable({transport=Native.new(opts),changed=opts.on_change,status='new',epoch=0},Client)
end
function Client:_changed()if self.changed then self.changed(self) end end
function Client:view()return self.snapshot end -- borrowed read-only, like terminal sessions
function Client:_accept(input,expected)
  local snapshot,why=Snapshot.validate(input);if not snapshot then return nil,why end
  if self.host_id and snapshot.host_id~=self.host_id then return nil,problem('Layout server changed; join it again explicitly') end
  if expected and snapshot.revision~=expected then return nil,problem('Invalid layout command acknowledgement') end
  local refs=references(snapshot)
  for id,v in pairs(refs)do
    local old=self.refs and self.refs[id]
    if old and (old.kind~=v.kind or old.terminal_id~=v.terminal_id or old.generation~=v.generation or old.agent_id~=v.agent_id)then
      return nil,problem('Layout changed an existing view reference')
    end
  end
  if self.revision and snapshot.revision==self.revision then
    if json.encode(snapshot)~=json.encode(self.snapshot) then return nil,problem('Layout changed without a new revision') end
    return true
  end
  if self.revision and snapshot.revision<self.revision then return true end
  self.host_id,self.revision=snapshot.host_id,snapshot.revision
  self.snapshot,self.refs=snapshot,refs
  return true
end
function Client:start(callback)
  callback=callback or function()end
  if self.closed or self.watch then callback(problem('Layout observation is already active or closed'));return end
  self.epoch=self.epoch+1;local epoch=self.epoch;local first=true
  self.status='connecting';self.error=nil;self:_changed()
  local request
  request=self.transport:request('GET','/layout/stream',nil,function(why)
    if self.closed or epoch~=self.epoch then return end
    self.watch=nil;self.status='disconnected';self.error=why or problem('Layout stream ended')
    if first then first=false;callback(self.error) end
    self:_changed()
  end,function(event,raw)
    if self.closed or epoch~=self.epoch then return end
    local decoded,input=pcall(json.decode,raw)
    local accepted,why
    if event=='message' and decoded then accepted,why=self:_accept(input) end
    if not accepted then error(why and why.message or 'Invalid layout stream event',0) end
    self.status=self.uncertain and 'uncertain' or 'live';self.error=nil
    if first then first=false;callback(nil,self) end
    self:_changed()
  end)
  if not request.done then self.watch=request end
  return request
end
function Client:refresh(callback)
  callback=callback or function()end
  if self.closed or self.refreshing then callback(problem('Layout refresh is unavailable'));return end
  self.refreshing=true
  return self.transport:request('GET','/layout',nil,function(why,value)
    if self.closed then return end
    self.refreshing=false
    if not why then local accepted;accepted,why=self:_accept(value) end
    if not why then self.uncertain=false;self.error=nil;self.status=self.watch and 'live' or 'disconnected'
    else self.error=why end
    self:_changed();callback(why,self.snapshot)
  end)
end
function Client:command(op,args,callback)
  callback=callback or function()end
  if self.closed or self.status~='live' or self.busy or self.uncertain then callback(problem('Layout is not ready for another command'));return end
  local body={host_id=self.host_id,revision=self.revision,op=op}
  for k,v in pairs(args or {})do
    if k=='host_id' or k=='revision' or k=='op' then callback(problem('Reserved layout command field'));return end
    body[k]=v
  end
  local encoded,text=pcall(json.encode,body)
  if not encoded or #text>8192 then callback(problem('Layout command exceeds its encoding limit'));return end
  local expected=self.revision+1;self.busy=true;self.error=nil;self:_changed()
  return self.transport:request('POST','/layout/commands',text,function(why,value,status)
    if self.closed then return end
    self.busy=false
    if not why then local accepted;accepted,why=self:_accept(value,expected) end
    if why then
      self.error=why
      if not status or status>=500 or why.kind~='http' then self.uncertain=true;self.status='uncertain' end
      if status==409 then self.status='conflict' end
    else self.error=nil;self.status=self.watch and 'live' or 'disconnected' end
    self:_changed();callback(why,self.snapshot)
    if why and status==409 then self:refresh() end -- refetch, never replay
  end)
end
function Client:close()
  if self.closed then return end
  self.closed=true;self.epoch=self.epoch+1;self.status='closed';self.watch=nil
  self.transport:close();self:_changed()
end
return M
