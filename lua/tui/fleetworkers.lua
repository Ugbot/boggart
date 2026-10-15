-- Own-process scheduler observation. Retain dirty terminal records until sent,
-- so a worker that starts and finishes in one resume sweep still appears.
local events=require 'events'
local json=require 'json'
local M={};local Workers={};Workers.__index=Workers
local LIMIT=512
local function short(value,limit)return tostring(value or ''):gsub('[%z\1-\31\127]',' '):sub(1,limit)end
function M.new(st)
  local self=setmetatable({st=st,entries={},order={},serial=0,sequence=0},Workers)
  self.started=events.on('swarm:actor_started',function(_,ev)self:start(ev.id)end)
  self.stopped=events.on('swarm:actor_stopped',function(_,ev)self:finish(ev)end)
  return self
end
function Workers:start(id)
  if id==self.st.coord.id then return end
  local rec=bog.thread and bog.thread.live_recs[id]
  local actor=bog.sched and bog.sched.by_id[id]
  if not rec or not actor or type(id)~='number' then return end
  local old=self.entries[id]
  if old and old.actor==actor then return end
  if old then
    -- Keep an unsent older incarnation in order; only the map targets live IDs.
    self.entries[id]=nil
  end
  if #self.order>=LIMIT then self.error='worker reporting capacity reached';return end
  self.serial=self.serial+1
  local e={actor=actor,record=rec,session_id=id,incarnation=self.serial,
    parent_session_id=rec.parent_id or self.st.coord.id,name=short(rec.spec_name or 'Worker',128),
    model=short(rec.session.model,256),live=true}
  if e.name==''then e.name='Worker'end
  self.entries[id]=e;self.order[#self.order+1]=e
end
function Workers:finish(ev)
  local e=self.entries[ev.id];if not e or not e.live then return end
  e.live=false
  e.state=ev.reason=='killed' and 'stopped' or (ev.reason=='crashed' or e.record.final_status=='error') and 'failed' or 'exited'
  e.error=e.state=='failed' and short(ev.detail or e.record.final_error or 'worker failed',512) or false
  e.actor,e.record=nil,nil -- Pending metadata must not retain a dead transcript/coroutine.
end
function Workers:poll(emit)
  for _,actor in ipairs((bog.sched and bog.sched.actors) or {})do self:start(actor.id)end
  if self.error then return nil,self.error end
  local sent=0;local keep={}
  for _,e in ipairs(self.order)do
    local state,activity=e.state,e.state
    if e.live then
      local actor=bog.sched.by_id[e.session_id]
      if actor~=e.actor then return nil,'worker lifecycle observation lost' end
      local pending=self.st.pending
      state=actor.paused and 'paused' or pending and pending.decision==nil and pending.agent_id==e.session_id
        and 'waiting_for_approval' or 'running'
      activity=actor.paused and 'paused' or state=='waiting_for_approval' and 'waiting on approval'
        or actor.status=='io' and 'waiting on I/O' or actor.status=='recv' and 'waiting on mail'
        or actor.status=='proc' and 'running a command' or actor.status=='blocked' and 'waiting for a decision' or 'running'
    end
    local value={session_id=e.session_id,incarnation=e.incarnation,parent_session_id=e.parent_session_id,
      name=e.name,model=e.model,state=state,activity=activity,error=e.error or false,can_stop=e.live}
    local signature=json.encode(value)
    if signature~=e.signature and sent<32 then
      self.sequence=self.sequence+1
      if not emit{type='worker',sequence=self.sequence,worker=value}then return nil,'worker channel unavailable'end
      e.signature=signature;sent=sent+1
    end
    if e.live or e.signature~=signature then keep[#keep+1]=e
    elseif self.entries[e.session_id]==e then self.entries[e.session_id]=nil end
  end
  self.order=keep;return true
end
function Workers:stop(id,incarnation)
  local e=self.entries[id]
  if not e or not e.live or e.incarnation~=incarnation or bog.sched.by_id[id]~=e.actor then return nil,'stale worker runtime'end
  local pending=self.st.pending
  if pending and pending.agent_id==id then pending.decision='reject';self.st.pending=nil;self.st.dirty=true end
  return bog.supervisor.kill(id)
end
function Workers:close()
  events.off(self.started);events.off(self.stopped)
  self.entries={};self.order={}
end
return M
