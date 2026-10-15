-- Observations only: a provider hook never grants execution or approval rights.
local M={};local Observer={};Observer.__index=Observer
local phases={SessionStart='idle',UserPromptSubmit='running',PreToolUse='running',
  PermissionRequest='waiting_for_approval',PostToolUse='running',PostToolUseFailure='running',
  Stop='idle',StopFailure='idle',SessionEnd='alive',Setup='alive'}
local notifications={permission_prompt='waiting_for_approval',idle_prompt='idle',
  elicitation_dialog='waiting_for_answer',elicitation_url_dialog='waiting_for_answer'}
local function label(s,n)return type(s)=='string' and #s>0 and #s<=n and not s:find('\0',1,true) and utf8.len(s)~=nil end
function M.new(provider)return setmetatable({provider=provider,retired={},identities=0,revision=0},Observer)end
function Observer:publish(fields)
  self.status=fields;self.revision=self.revision+1
end
function Observer:invalidate(reason)
  self:publish{state='alive',activity=reason..'; agent activity unknown',attention=false,reported_event=false}
end
function Observer:apply(event,stamp)
  if self.provider~='claude' or self.disabled then return nil,'unsupported provider or expired observer'end
  if type(event)~='table' or type(stamp)~='number' or stamp%1~=0 or stamp<1 or stamp>9007199254740991 then return nil,'invalid event'end
  if stamp<=(self.stamp or 0) then return nil,'stale event'end
  local name,sid=event.hook_event_name,event.session_id
  local phase=phases[name] or name=='Notification' and notifications[event.notification_type]
  if not phase or not label(sid,128) or event.agent_id~=nil and not label(event.agent_id,128)then return nil,'invalid or unsupported event'end
  if self.retired[sid] then return nil,'retired provider session'end
  if self.ended and self.session==sid then return nil,'provider session ended'end
  if self.session and (event.agent_id or false)~=self.root then return nil,'subagent event'end
  if name=='SessionStart' or not self.session then
    if name~='SessionStart' and event.agent_id then return nil,'unbound subagent event'end
    if self.session~=sid then
      if self.identities>=128 then self.disabled=true;self:invalidate('provider session history full');return nil,'session history full'end
      if self.session then self.retired[self.session]=true end
      self.identities=self.identities+1;self.session=sid;self.root=event.agent_id or false
    end
    self.ended=false
  elseif sid~=self.session or (event.agent_id or false)~=self.root then return nil,'different provider session or subagent'end
  if self.ended then return nil,'provider session ended'end
  if name=='PreToolUse' and event.tool_name=='AskUserQuestion' then phase='waiting_for_answer'end
  if name=='SessionStart' and event.source=='compact' then phase=self.status and self.status.state or 'alive'end
  local attention=name=='Stop' or name=='StopFailure' or phase=='waiting_for_approval' or phase=='waiting_for_answer' or name=='Notification'
  local activity=name=='StopFailure' and 'reported turn failure; awaiting input'
    or name=='SessionEnd' and 'provider session ended; awaiting process exit' or 'reported '..phase
  self.stamp=stamp;self.ended=name=='SessionEnd'
  self:publish{state=phase,activity=activity,session_id=sid,attention=attention,
    reported_event=name,reported_at=stamp}
  return true
end
function Observer:poll()
  if self.sent==self.revision then return end
  self.sent=self.revision
  if not self.status then return end
  local fields={};for k,v in pairs(self.status)do fields[k]=v end;return fields
end
return M
