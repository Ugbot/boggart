-- Shared Fleet observer/command policy over the existing native UDS client.
local Native=require 'terminal.client';local Snapshot=require 'bmux.fleetsnapshot'
local Shape=require 'bmux.agentcommands';local Decode=require('terminal.replica').decode;local json=require 'json'
local M={};local Client={};Client.__index=Client
local function problem(message,kind)return {kind=kind or 'state',message=message}end
local function label(value,limit)return type(value)=='string'and #value>0 and #value<=limit
  and not value:find('[%z\1-\31\127]')and utf8.len(value)~=nil end
function M.new(opts)
  local id=opts.client_id or serve.token(12);local sequence=opts.sequence or 0
  assert(type(id)=='string'and #id>0 and #id<=64 and id:match('^[%w_-]+$')and Shape.integer(sequence,0),'invalid Fleet command identity')
  return setmetatable({transport=Native.new(opts),changed=opts.on_change,host_id=opts.host_id,
    client_id=id,sequence=sequence,status='new',epoch=0},Client)
end
function Client:_changed()if self.changed then self.changed(self)end end
function Client:_status()self.status=self.uncertain and 'uncertain'or self.live and 'live'or 'disconnected'end
function Client:view()return self.snapshot end -- borrowed read-only
function Client:find(id)return self.records and self.records[id]end
function Client:can_command()return not self.closed and self.live and not self.busy and not self.pending or false end
function Client:_accept(input)
  local snapshot,ids=Snapshot.validate(input);if not snapshot then return nil,ids end
  if self.host_id and snapshot.host_id~=self.host_id then return nil,problem('Fleet server changed; join it again explicitly','protocol')end
  if self.revision and snapshot.revision<self.revision then return true end
  if self.revision and snapshot.revision==self.revision then
    if json.encode(snapshot)~=json.encode(self.snapshot)then return nil,problem('Fleet changed without a new revision','protocol')end
    return true
  end
  for id,r in pairs(ids)do
    local old=self.records and self.records[id]
    if old and (r.generation<old.generation or r.generation==old.generation
      and (r.terminal_id~=old.terminal_id or r.terminal_generation~=old.terminal_generation))then
      return nil,problem('Fleet retargeted an existing runtime','protocol')
    end
  end
  self.host_id,self.revision,self.snapshot,self.records=snapshot.host_id,snapshot.revision,snapshot,ids
  return true
end
function Client:start(callback)
  callback=callback or function()end
  if self.closed or self.watch then callback(problem('Fleet observation is already active or closed'));return end
  self.epoch=self.epoch+1;local epoch=self.epoch;local first=true
  self.live=false;self.status='connecting';if not self.uncertain then self.error=nil end;self:_changed()
  local request=self.transport:request('GET','/fleet/stream',nil,function(why)
    if self.closed or epoch~=self.epoch then return end
    self.watch=nil;self.live=false;self.error=why or problem('Fleet stream ended');self:_status()
    if first then first=false;callback(self.error)end;self:_changed()
  end,function(event,raw)
    if self.closed or epoch~=self.epoch then return end
    local input,why=Decode(raw);local accepted
    if event=='message'and input then accepted,why=self:_accept(input)end
    if not accepted then error(why and why.message or 'Invalid Fleet event',0)end
    self.live=true;if not self.uncertain then self.error=nil end;self:_status()
    if first then first=false;callback(nil,self)end;self:_changed()
  end)
  if not request.done then self.watch=request end
  return request
end
function Client:refresh(callback)
  callback=callback or function()end
  if self.closed or self.refreshing then callback(problem('Fleet refresh unavailable'));return end
  self.refreshing=true
  return self.transport:request('GET','/fleet',nil,function(why,input)
    if self.closed then return end;self.refreshing=false
    if not why then local accepted;accepted,why=self:_accept(input)end
    self.error=why or self.uncertain and self.error or nil;self:_status();self:_changed();callback(why,self.snapshot)
  end)
end
local function consumed(body,pending)
  local r=type(body)=='table'and body.receipt
  return type(r)=='table'and r.client_id==pending.body.client_id and r.command_seq==pending.body.command_seq
end
local function valid_result(value,p)
  if type(value)~='table'or not consumed(value,p)then return false end
  if p.route=='launch'then
    return label(value.agent_id,256)
      and Shape.integer(value.generation)and type(value.terminal_id)=='string'and value.terminal_id:match('^[%w_-]+$')
      and #value.terminal_id<=128 and Shape.integer(value.terminal_generation)and (value.reused==nil or type(value.reused)=='boolean')
  end
  return value.accepted==true and value.agent_id==p.body.agent_id and value.generation==p.body.generation
    and (value.command_id==nil or label(value.command_id,128))
end
function Client:_send(callback)
  local pending=self.pending;self.busy=true;self:_changed()
  return self.transport:request('POST','/fleet/'..pending.route,pending.text,function(why,value,status)
    if self.closed then return end;self.busy=false
    local receipt=why and why.response or value
    local known=consumed(receipt,pending)
    if why and why.kind=='http'and type(receipt)=='table'and label(receipt.error,1024)then why.message=receipt.error end
    if not why and not valid_result(value,pending)then why=problem('Invalid Fleet command acknowledgement','protocol');known=false end
    if known then
      self.sequence=pending.body.command_seq;self.pending=nil;self.uncertain=false
    elseif why and why.kind=='http'and status and status<500 and not (type(receipt)=='table'and receipt.receipt~=nil)then
      self.pending=nil;self.uncertain=false -- authenticated admission refusal, no sequence consumed
    else self.uncertain=true end
    self.error=why;self:_status();self:_changed();callback(why,value,status)
  end)
end
function Client:_mutate(route,fields,callback)
  callback=callback or function()end
  if not self:can_command()then callback(problem('Fleet is not ready for another command'));return end
  if type(fields)~='table'or getmetatable(fields)~=nil then callback(problem('Fleet command fields required'));return end
  local body={host_id=self.host_id,client_id=self.client_id,command_seq=self.sequence+1}
  for k,v in pairs(fields)do
    if k=='host_id'or k=='client_id'or k=='command_seq'then callback(problem('Reserved Fleet command field'));return end
    body[k]=v
  end
  local valid,why=Shape.validate(route,body);if not valid then callback(problem(why));return end
  local encoded,text=pcall(json.encode,body)
  if not encoded or #text>65536 then callback(problem('Fleet command encoding limit exceeded'));return end
  self.pending={route=route,body=body,text=text};return self:_send(callback)
end
function Client:launch(opts,callback)return self:_mutate('launch',opts,callback)end
function Client:command(id,generation,action,payload,callback)
  callback=callback or function()end
  local record=self:find(id)
  if not record or record.generation~=generation or not record.capabilities[action]then callback(problem('Agent action expired or unavailable'));return end
  local fields={agent_id=id,generation=generation,action=action}
  if payload~=nil and (type(payload)~='table'or getmetatable(payload)~=nil)then callback(problem('Agent action fields required'));return end
  for k,v in pairs(payload or {})do
    if k=='agent_id'or k=='generation'or k=='action'then callback(problem('Reserved agent action field'));return end
    fields[k]=v
  end
  if action=='prompt'and fields.input_revision==nil then fields.input_revision=record.input_revision end
  return self:_mutate('commands',fields,callback)
end
function Client:retry(callback)
  callback=callback or function()end
  if self.closed or self.busy or not self.pending then callback(problem('No uncertain Fleet command to retry'));return end
  return self:_send(callback)
end
function Client:close()
  if self.closed then return end;self.closed=true;self.epoch=self.epoch+1;self.live=false;self.status='closed'
  self.transport:close();self.watch=nil;self.pending=nil;self.busy=false;self:_changed()
end
return M
