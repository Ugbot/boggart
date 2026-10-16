-- Presentation adapter in the common Fleet; execution stays on the server.
local M={};local Source={};Source.__index=Source
local function key(host,id)return 'remote:'..host..':'..type(id)..':'..tostring(id)end
function M.new(registry,client,focus,changed)
  local self=setmetatable({registry=registry,client=client,focus=focus,changed=changed,rows={},mapped={},errors={}},Source)
  self.name='fleet-client:'..client.client_id
  local owner={}
  owner.focus=function(rec)
    if self.closed or not self.focus then return nil,'server presentation is disconnected'end
    return self.focus(rec.remote_id,rec.generation)
  end
  for _,action in ipairs{'prompt','interrupt','approve','stop'}do
    owner[action]=function(rec,payload)return self:send(rec,action,payload)end
  end
  registry:set_source(self.name,function()return self.rows end,owner)
  self:update();return self
end
function Source:find(id)return self.mapped[id]end
function Source:update()
  if self.closed then return end
  if self.client.closed then self:close();return end
  local snapshot=self.client:view();local rows,mapped,errors={},{},{}
  if snapshot then for i,wire in ipairs(snapshot.agents)do
    local row=self.mapped[wire.id]
    if not row or row.generation~=wire.generation then
      row={t0=os.time()};self.errors[key(snapshot.host_id,wire.id)]=nil
    end
    local since=row.t0
    for k in pairs(row)do row[k]=nil end
    for k,v in pairs(wire)do if k~='capabilities'and k~='request'and k~='control_result'then row[k]=v end end
    row.id=key(snapshot.host_id,wire.id);row.remote_id=wire.id;row.short_id='R'..i
    row.fleet_origin='external';row.fleet_remote=true;row.kind=wire.name;row.worker=wire.worker_incarnation~=nil
    row.t0=since;row.tools=0;row.lines={};row.partial=''
    row.parent=wire.parent and key(snapshot.host_id,wire.parent)or nil
    row.capabilities={focus=self.client.live and wire.terminal_id~=nil and self.focus~=nil or false}
    for _,action in ipairs{'prompt','interrupt','approve','stop'}do
      row.capabilities[action]=self.client:can_command()and wire.capabilities[action]or false
    end
    if wire.request then row.request={id=wire.request.id,kind=wire.request.kind,name=wire.request.name,summary=wire.request.summary}end
    if wire.control_result then
      row.control_result={id=wire.control_result.id,accepted=wire.control_result.accepted,error=wire.control_result.error}
    end
    if not self.client.live then row.state='unreachable';row.activity='server observation disconnected'end
    row.error=self.errors[row.id]or row.error or self.client.error and self.client.error.message
    errors[row.id]=self.errors[row.id]
    rows[#rows+1]=row;mapped[wire.id]=row
  end end
  self.rows,self.mapped,self.errors=rows,mapped,errors
  self.registry:_changed();if self.changed then self.changed()end
end
function Source:send(row,action,payload)
  if self.closed or self.mapped[row.remote_id]~=row then return nil,'agent runtime expired'end
  local id,generation=row.id,row.generation;local immediate,finished
  self.errors[id]=nil
  local request=self.client:command(row.remote_id,generation,action,payload,function(why)
    finished=true;immediate=why
    if self.closed or self.mapped[row.remote_id]~=row or row.generation~=generation then return end
    self.errors[id]=why and why.message or nil;self:update()
  end)
  if finished and immediate then return nil,immediate.message end
  if request then return true end
  return nil,'agent control unavailable'
end
function Source:close()
  if self.closed then return end;self.closed=true
  self.registry:set_source(self.name,nil);self.rows={};self.mapped={};self.errors={}
end
return M
