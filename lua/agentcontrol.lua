-- Host side of the private v1 TUI channel; transport/lifetime stays in C.
local json=require 'json'
local M={};local Control={};Control.__index=Control
local phases={idle=true,running=true,waiting_for_approval=true,waiting_for_answer=true}
function M.new(channel,id,generation)
  local self=setmetatable({channel=channel,id=id,generation=generation,serial=0,sequence=0,pending={},pending_count=0},Control)
  assert(channel:send(json.encode{v=1,type='bind',id=id,generation=generation}))
  return self
end
function Control:fail(reason)
  self.channel:close();self.pending={};self.pending_count=0
  self.status=nil;self.error=reason
  return {state='alive',activity='agent control unavailable; activity unknown',error=reason,
    capabilities={prompt=false,interrupt=false,approve=false},request=false}
end
function Control:poll()
  if self.error then return end
  local fields
  for _=1,64 do
    local bytes=self.channel:receive();if not bytes then break end
    local ok,value=pcall(json.decode,bytes)
    if not ok or type(value)~='table' or value.v~=1 or value.id~=self.id or value.generation~=self.generation then
      return self:fail('invalid agent control frame')
    end
    if value.type=='state' then
      if not phases[value.state] or type(value.sequence)~='number' or value.sequence%1~=0 or value.sequence<=self.sequence
        or type(value.input_revision)~='number' or value.input_revision%1~=0 or value.input_revision<0
        or type(value.draft_bytes)~='number' or value.draft_bytes<0
        or type(value.session_id)~='number' or type(value.model)~='string' or #value.model>1024
        or type(value.capabilities)~='table' then return self:fail('invalid agent state')end
      for _,action in ipairs{'prompt','interrupt','approve'}do
        if type(value.capabilities[action])~='boolean' then return self:fail('invalid agent capability')end
      end
      if value.request and (type(value.request)~='table' or type(value.request.id)~='string'
        or #value.request.id>128 or value.request.kind~='approval' or type(value.request.name)~='string'
        or #value.request.name>256 or type(value.request.summary)~='string'
        or #value.request.summary>2048) then return self:fail('invalid approval request')end
      self.sequence=value.sequence;self.status=value
      fields=fields or {};for _,key in ipairs{'state','session_id','model','input_revision','draft_bytes','capabilities'}do fields[key]=value[key]end
      fields.request=value.request or false;fields.activity=value.state;fields.error=false
    elseif value.type=='result' then
      if type(value.command_id)~='string' or not self.pending[value.command_id] or type(value.accepted)~='boolean'
        or value.error~=nil and (type(value.error)~='string' or #value.error>1024) then return self:fail('invalid command result')end
      self.pending[value.command_id]=nil;self.pending_count=self.pending_count-1
      fields=fields or {};fields.control_result={id=value.command_id,accepted=value.accepted,error=value.error}
    else return self:fail('unsupported agent control frame')end
  end
  local revision=self.channel:revision()
  if revision~=self.transport_revision then
    self.transport_revision=revision
    local transport=self.channel:state()
    if transport.closed and not self.error then return self:fail(transport.error or 'control channel closed')end
  end
  return fields
end
function Control:command(action,payload)
  if not self.status or self.error or not self.status.capabilities[action] then return nil,'agent control is unavailable' end
  if self.pending_count>=32 then return nil,'too many pending commands' end
  self.serial=self.serial+1
  local command_id='command:'..self.serial
  local cmd={v=1,type='command',id=self.id,generation=self.generation,command_seq=self.serial,
    command_id=command_id,action=action,input_revision=self.status.input_revision}
  if action=='prompt' then
    if type(payload)~='table' or type(payload.text)~='string' or #payload.text>16384 then return nil,'invalid prompt' end
    cmd.text=payload.text
    if payload.input_revision~=nil then cmd.input_revision=payload.input_revision end
  elseif action=='approve' then
    if type(payload)~='table' then return nil,'approval request required' end
    cmd.request_id=payload.request_id;cmd.decision=payload.decision
  elseif action~='interrupt' then return nil,'unsupported command' end
  local sent,error=self.channel:send(json.encode(cmd));if not sent then return nil,error end
  self.pending[command_id]=true;self.pending_count=self.pending_count+1;return true,command_id
end
return M
