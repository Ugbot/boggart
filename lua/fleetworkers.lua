-- Common-roster rows whose scheduler lives in a different Boggart TUI process.
-- Native session/incarnation references never become global Fleet identities.
local M={};local Mirror={};Mirror.__index=Mirror
local ended={exited=true,failed=true,stopped=true}
local function key(id,incarnation)return string.format('%d:%d',id,incarnation)end
function M.new(registry,parent,control,focus)
  return setmetatable({registry=registry,parent=parent,control=control,focus=focus,children={}},Mirror)
end
function Mirror:prune()
  if self.evictions==self.registry.evictions then return end
  self.evictions=self.registry.evictions
  for ref,rec in pairs(self.children)do if self.registry.agents[rec.id]~=rec then self.children[ref]=nil end end
end
function Mirror:apply(updates,results)
  self:prune()
  for _,w in ipairs(updates or {})do
    local ref=key(w.session_id,w.incarnation);local rec=self.children[ref]
    if not rec then
      local ok,created=pcall(self.registry.register,self.registry,{provider='boggart',name=w.name,
        parent=self.parent.id,cwd=self.parent.cwd,session_id=w.session_id})
      if not ok then return nil,tostring(created)end
      rec=created;rec.worker=true;rec.worker_incarnation=w.incarnation
      self.children[ref]=rec
      local session_id,incarnation=w.session_id,w.incarnation
      self.registry:bind(rec.id,rec.generation,{focus=self.focus,evictable_history=true,
        stop=function()return self.control:command('worker_stop',{worker_session_id=session_id,worker_incarnation=incarnation})end})
    end
    if ended[rec.state] and w.state~=rec.state then return nil,'worker reported activity after its terminal state'end
    self.registry:update(rec.id,rec.generation,{state=w.state,model=w.model,activity=w.activity,
      parent_session_id=w.parent_session_id,error=w.error})
    if not ended[w.state]then rec.capabilities.stop=w.can_stop end
  end
  for _,result in ipairs(results or {})do
    local rec=self.children[key(result.worker_session_id,result.worker_incarnation)]
    if rec then rec.control_result=result end
  end
  self:prune();return true
end
function Mirror:unreachable(reason)
  for _,rec in pairs(self.children)do
    if self.registry.agents[rec.id]==rec and not ended[rec.state]then
      self.registry:update(rec.id,rec.generation,{state='unreachable',activity='owning TUI control unavailable',error=reason})
      rec.capabilities.stop=false
    end
  end
end
function Mirror:close(reason,release)
  for _,rec in pairs(self.children)do
    if self.registry.agents[rec.id]==rec then
      if not ended[rec.state]then
        self.registry:update(rec.id,rec.generation,{state='stopped',activity=reason or 'owning TUI stopped'})
      end
      if release then self.registry:retire(rec.id,rec.generation,rec.state,rec.error)end
    end
  end
  if release then self.children={}end
end
return M
