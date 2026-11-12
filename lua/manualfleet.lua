-- Pane-scoped registration for native shell wrappers. PIDs are metadata only.
local json=require 'json'
local M={};local Service={};Service.__index=Service
local ended={exited=true,failed=true,stopped=true}
local function label(value,limit)
  return type(value)=='string' and #value>0 and #value<=limit and not value:find('\0',1,true)
end
local function integer(value,low,high)return type(value)=='number' and value%1==0 and value>=low and value<=high end
local function alive(pane)local ok,running=pcall(pane.alive);return ok and running end
local function answer(code,value)return code,json.encode(value),{content_type='application/json'}end
function M.new(opts)
  return setmetatable({registry=assert(opts.registry),clock=assert(opts.clock),token=serve.token,
    verify=serve.verify_token,panes={},entries={},ttl=opts.ttl or 4,changed=opts.changed},Service)
end
function Service:pane(opts)
  local count=0;for _ in pairs(self.panes)do count=count+1 end;assert(count<512,'pane registration capacity reached')
  local pane={id='pane:'..self.token(12),token=self.token(24),focus=assert(opts.focus),alive=assert(opts.alive),cwd=opts.cwd}
  self.panes[pane.id]=pane;return pane
end
function Service:observe(rec,pane)
  assert(self.registry.agents[rec.id]==rec and self.panes[pane.id]==pane and not self.entries[rec.id],'invalid report owner')
  local entry={pane=pane.id,rec=rec,event_token=self.token(24),last=self.clock(),managed=true,
    events=require('providerevents').new(rec.provider)}
  self.entries[rec.id]=entry;return entry
end
function Service:revoke(id)
  self.panes[id]=nil
  for _,entry in pairs(self.entries)do if entry.pane==id then
    local rec=entry.rec
    if not entry.managed and self.registry.agents[rec.id]==rec then
      self.registry:update(rec.id,rec.generation,{activity=ended[rec.state] and rec.activity or 'registration retired; owning pane closed; process state unknown'})
      self.registry:retire(rec.id,rec.generation,ended[rec.state] and rec.state or 'unreachable')
    end
    entry.finished=true;entry.lease=false;entry.event_token=false;entry.events:invalidate('registration retired')
  end end
end
function Service:expire()
  for id,pane in pairs(self.panes)do if not alive(pane)then self:revoke(id)end end
  local now=self.clock()
  for id,entry in pairs(self.entries)do
    if self.registry.agents[id]~=entry.rec then self.entries[id]=nil
    elseif not entry.managed and not entry.finished and now-entry.last>self.ttl and entry.rec.state~='unreachable' then
      entry.events:invalidate('wrapper heartbeat expired')
      self.registry:update(id,entry.rec.generation,{state='unreachable',activity='wrapper heartbeat expired; process state unknown',attention=false,reported_event=false})
      if self.changed then self.changed()end
    end
  end
end
function Service:handle(req)
  if not req.authenticated or req.remote~='unix' then return answer(403,{error='private local transport required'})end
  if req.method=='GET' and req.path=='/health' then return answer(200,{ok=true,transport='unix'})end
  if req.method~='POST' then return answer(404,{error='unknown route'})end
  local parsed,body=pcall(json.decode,req.body or '')
  if not parsed or type(body)~='table' then return answer(400,{error='invalid JSON object'})end
  local pane=type(body.pane)=='string' and self.panes[body.pane]
  if not pane or not label(body.pane_token,128) or not self.verify(pane.token,body.pane_token) then return answer(403,{error='invalid pane context'})end
  if not alive(pane)then self:revoke(pane.id);return answer(403,{error='pane is closed'})end
  if req.path=='/bmux/agents/list' then
    local rows={};local offset,limit=body.offset or 0,body.limit or 64
    if not integer(offset,0,4096) or not integer(limit,1,64)then return answer(400,{error='invalid page'})end
    local total=0
    for _,id in ipairs(self.registry.order)do local entry=self.entries[id]
      if entry and entry.pane==pane.id then
        total=total+1;local rec=entry.rec
        if total>offset and #rows<limit then rows[#rows+1]={id=rec.id,provider=rec.provider,name=rec.name,state=rec.state,pid=rec.pid}end
      end
    end
    return answer(200,{agents=#rows>0 and rows or json.array,total=total,next_offset=offset+#rows<total and offset+#rows or json.null})
  end
  if req.path=='/bmux/agents/register' then
    if not label(body.provider,128) or not label(body.name,256) or body.cwd~=nil and not label(body.cwd,4096)then return answer(400,{error='invalid agent metadata'})end
    self:expire()
    local created,rec=pcall(self.registry.register,self.registry,{provider=body.provider,name=body.name,cwd=body.cwd or pane.cwd})
    if not created then return answer(503,{error='Fleet capacity reached'})end
    if self.panes[pane.id]~=pane then self.registry:retire(rec.id,rec.generation,'unreachable');return answer(403,{error='pane is closed'})end
    rec.manual=true;rec.pane_id=pane.id
    local entry=self:observe(rec,pane);entry.managed=false;entry.lease=self.token(24)
    self.registry:bind(rec.id,rec.generation,{focus=pane.focus,evictable_history=true})
    self.registry:update(rec.id,rec.generation,{state='starting',activity='starting wrapped process'})
    return answer(201,{agent_id=rec.id,lease=entry.lease,event_token=entry.event_token})
  end
  local entry=type(body.agent_id)=='string' and self.entries[body.agent_id]
  if req.path=='/bmux/agents/notify' then
    if not entry or entry.finished or entry.rec.retired or entry.pane~=pane.id or body.provider~=entry.rec.provider
      or not label(body.event_token,128) or not self.verify(entry.event_token,body.event_token)then return answer(403,{error='invalid event capability'})end
    local applied,why=entry.events:apply(body.event,body.stamp)
    if not applied then return answer(409,{error=why})end
    self.registry:update(entry.rec.id,entry.rec.generation,entry.events.status)
    if self.changed then self.changed()end
    return answer(200,{ok=true})
  end
  if not entry or entry.finished or not entry.lease or entry.pane~=pane.id or not label(body.lease,128) or not self.verify(entry.lease,body.lease) then return answer(403,{error='invalid registration lease'})end
  if body.pid~=nil and not integer(body.pid,0,2147483647)then return answer(400,{error='invalid process metadata'})end
  local fields={}
  if body.pid and body.pid>0 then fields.pid=body.pid end
  if req.path=='/bmux/agents/heartbeat' then
    entry.last=self.clock()
    for k,v in pairs(entry.events.status or {state='alive',activity='wrapped process alive; agent activity unknown'})do fields[k]=v end
  elseif req.path=='/bmux/agents/finish' then
    if not integer(body.exit_status,0,255) or not integer(body.term_signal,0,128)then return answer(400,{error='invalid process outcome'})end
    fields.exit_status=body.exit_status;fields.term_signal=body.term_signal
    fields.state=body.exit_status==0 and body.term_signal==0 and 'exited' or 'failed';fields.activity='wrapped process '..fields.state
    entry.finished=true;entry.lease=false;entry.event_token=false
  else return answer(404,{error='unknown route'})end
  self.registry:update(entry.rec.id,entry.rec.generation,fields)
  return answer(200,{ok=true,agent_id=entry.rec.id})
end
return M
