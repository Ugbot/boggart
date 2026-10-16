-- Server agent owners. Native terminals/channels and the common Fleet execute.
local uv=require 'uv';local json=require 'json';local Shape=require 'bmux.agentcommands'
local M={};local Host={};Host.__index=Host
local ended={exited=true,failed=true,stopped=true}
local function fail(status,message)return nil,{status=status,message=message}end
local function safe(value,limit)
  if type(value)~='string'then return nil end
  if not utf8.len(value)then return '(invalid UTF-8)'end
  if #value>limit then
    local stop=limit+1
    while stop>1 and (value:byte(stop)or 0)>=128 and value:byte(stop)<192 do stop=stop-1 end
    value=value:sub(1,stop-1)
  end
  return value:gsub('[%z\1-\31\127]',' ')
end
function M.new(terminals,server,host_id,opts)
  opts=opts or {}
  local self=setmetatable({terminals=terminals,server=server,host_id=host_id,
    registry=opts.registry or require('fleet').default,sessions={},revision=0,dirty=true,
    executable=opts.executable or uv.exepath(),channel='fleet:'..host_id,
    receipts=require('bmux.receipts').new(opts.max_clients)},Host)
  self.async=uv.new_async(function()self:_broadcast()end);self.async:unref()
  self.registry:watch(self.channel,function()self:_changed()end)
  return self
end
function Host:_changed()
  if self.closed then return end
  self.dirty=true
  if self.server:clients(self.channel)>0 then self.async:send()end
end
function Host:_session(rec)return self.sessions[rec.id]or self.sessions[rec.parent]end
function Host:_record(rec)
  local out={id=rec.id,generation=rec.generation or 1,provider=safe(rec.provider,128)or 'boggart',
    name=safe(rec.name or rec.kind,256)or 'agent',state=safe(rec.state,128)or 'unknown',
    activity=safe(rec.activity,256)or '',capabilities={}}
  for _,k in ipairs{'cwd','model','error'}do if type(rec[k])=='string'then out[k]=safe(rec[k],k=='cwd'and 4096 or 1024)end end
  for _,k in ipairs{'pid','exit_status','term_signal','bytes','session_id','input_revision','draft_bytes','worker_incarnation'}do
    if Shape.integer(rec[k],k=='exit_status'and -1 or 0)then out[k]=rec[k]end
  end
  if type(rec.parent)=='string'or type(rec.parent)=='number'then out.parent=rec.parent end
  local owner=self:_session(rec)
  if owner then
    out.terminal_id=owner.entry.id;out.terminal_generation=owner.entry.generation
    for _,action in ipairs{'stop','prompt','interrupt','approve'}do out.capabilities[action]=rec.capabilities[action]==true end
  end
  if type(rec.request)=='table'then
    out.request={id=safe(rec.request.id,128),kind='approval',name=safe(rec.request.name,256),summary=safe(rec.request.summary,2048)}
  end
  if type(rec.control_result)=='table'then
    local r=rec.control_result;out.control_result={id=safe(r.id,128),accepted=r.accepted==true,error=safe(r.error,1024)}
  end
  return out
end
function Host:encoded()
  if self.closed then return fail(503,'Fleet host is closed')end
  if self.dirty then
    local agents={}
    for _,rec in ipairs(self.registry:records())do
      if #agents>=1024 then self.error={status=413,message='Fleet snapshot record limit exceeded'};self.dirty=false;return nil,self.error end
      agents[#agents+1]=self:_record(rec)
    end
    local fingerprint=json.encode(agents[1]and agents or json.array)
    if #fingerprint>4*1024*1024-512 then
      self.error={status=413,message='Fleet snapshot byte limit exceeded'};self.dirty=false;return nil,self.error
    end
    if fingerprint~=self.fingerprint then
      if self.fingerprint then self.revision=self.revision+1 end
      self.fingerprint=fingerprint
      self.body=json.encode{v=1,host_id=self.host_id,revision=self.revision,agents=agents[1]and agents or json.array}
    end
    self.dirty=false;self.error=nil
  end
  if self.error then return nil,self.error end
  return self.body
end
function Host:snapshot()
  local body,why=self:encoded();if not body then return nil,why end;return json.decode(body)
end
function Host:_broadcast()
  if self.closed then return end
  local body=self:encoded()
  if not body then self.server:close_streams(self.channel);return end
  if self.broadcasted~=self.revision then
    self.server:broadcast('message',body,self.channel);self.broadcasted=self.revision
  end
end
function Host:_release_observation(s)
  if self.terminals.entries[s.entry.id]==s.entry then self.terminals:observe(s.entry,'fleet',nil)end
  if s.control then s.control.channel:watch(nil);s.control.channel:close()end
end
function Host:_prune()
  for id,s in pairs(self.sessions)do if self.registry.agents[id]~=s.rec then
    self:_release_observation(s);if s.workers then s.workers:close('owning Fleet row retired',true)end;self.sessions[id]=nil
  end end
end
function Host:_refresh(s)
  if self.closed then return end
  if self.registry.agents[s.rec.id]~=s.rec then self:_prune();return end
  local fields={}
  if s.control then
    for _=1,2 do
      local semantic=s.control:poll()
      if semantic then
        if s.workers then
          local applied,why=s.workers:apply(semantic.workers,semantic.worker_results)
          if not applied then semantic=s.control:fail(why)end
        end
        for k,v in pairs(semantic)do fields[k]=v end
      end
      if s.control.channel:state().received_frames==0 or s.control.error then break end
    end
    if s.control.error then s.workers:unreachable(s.control.error);s.control.channel:watch(nil)end
  end
  local p=self.terminals:status(s.entry)
  fields.state=s.entry.closed and (ended[p.state]and p.state or 'stopped')
    or ended[p.state]and p.state or s.control and s.control.status and s.control.status.state or 'alive'
  fields.pid=p.pid;fields.bytes=p.bytes;fields.exit_status=p.exit_status;fields.term_signal=p.term_signal
  fields.activity=ended[fields.state]and 'process '..fields.state or fields.activity
    or (s.control and s.control.status and fields.state or 'process alive; agent activity unknown')
  if p.error then fields.error=p.error end
  self.registry:update(s.rec.id,s.rec.generation,fields)
  if ended[fields.state]then
    if s.workers then s.workers:close('owning TUI '..fields.state)end
    self:_release_observation(s)
  end
  self:_changed()
end
function Host:_launch(b)
  self:_prune()
  if b.resume_id then for _,s in pairs(self.sessions)do
    if s.rec.provider=='boggart'and tostring(s.rec.session_id)==tostring(b.resume_id)and not ended[s.rec.state]and not s.entry.closed then
      return {agent_id=s.rec.id,generation=s.rec.generation,terminal_id=s.entry.id,terminal_generation=s.entry.generation,reused=true}
    end
  end end
  local command=b.cmd or self.executable
  local executable_name=command:match('([^/\\]+)$')
  if b.provider=='boggart'and not b.cmd and executable_name~='boggart'and executable_name~='boggart.exe'then return fail(503,'Boggart CLI path must be configured on this host')end
  local args=b.args
  if args==nil then
    args=b.provider=='boggart'and {'--tui'}or {}
    if b.resume_id then args[#args+1]='--resume';args[#args+1]=tostring(b.resume_id)end
  end
  local registered,rec=pcall(self.registry.register,self.registry,{provider=b.provider,name=b.name or b.provider,cwd=b.cwd or uv.cwd(),session_id=b.resume_id})
  if not registered then return fail(503,'Fleet capacity reached')end
  local record,why=self.terminals:open({cmd=command,args=args,cwd=b.cwd,cols=b.cols,rows=b.rows,history=b.history},{control=b.provider=='boggart'})
  if not record then self.registry:retire(rec.id,1,'failed',why.message);return nil,why end
  local entry=assert(self.terminals:find(record.id,record.generation))
  local s={rec=rec,entry=entry};self.sessions[rec.id]=s
  if entry.term and b.provider=='boggart'then
    local channel=entry.term:channel()
    if channel then s.control=require('agentcontrol').new(channel,rec.id,rec.generation)
      s.workers=require('fleetworkers').new(self.registry,rec,s.control,nil)end
  end
  local owner={evictable_history=true,
    stop=function()local result,error=self.terminals:close(entry.id,entry.generation);if result then return true end;return nil,error.message end,
    prompt=s.control and function(_,payload)return s.control:command('prompt',payload)end,
    interrupt=s.control and function()return s.control:command('interrupt')end,
    approve=s.control and function(_,payload)return s.control:command('approve',payload)end}
  self.registry:bind(rec.id,rec.generation,owner)
  if entry.term then
    assert(self.terminals:observe(entry,'fleet',function()self:_refresh(s)end))
    if s.control then s.control.channel:watch(function()self:_refresh(s)end)end
  end
  self:_refresh(s)
  return {agent_id=rec.id,generation=rec.generation,terminal_id=entry.id,terminal_generation=entry.generation}
end
function Host:_command(b)
  local rec=self.registry.agents[b.agent_id]
  if not rec then return fail(404,'unknown Fleet agent')end
  if rec.generation~=b.generation then return fail(409,'stale agent runtime')end
  local s=self:_session(rec);if not s then return fail(403,'agent execution is not owned by this server')end
  self:_refresh(s)
  if b.action=='prompt'and rec.input_revision~=b.input_revision then return fail(409,'agent input revision changed')end
  if b.action=='approve'and (type(rec.request)~='table'or rec.request.id~=b.request_id)then return fail(409,'approval request changed')end
  local accepted,id=self.registry:control(rec.id,b.generation,b.action,{text=b.text,input_revision=b.input_revision,request_id=b.request_id,decision=b.decision})
  if not accepted then return fail(409,type(id)=='string'and id or 'agent action unavailable')end
  self:_changed();return {accepted=true,agent_id=rec.id,generation=rec.generation,command_id=id}
end
function Host:submit(route,b)
  local valid,why=Shape.validate(route,b);if not valid then return fail(400,why)end
  if self.closed then return fail(503,'Fleet host is closed')end
  if b.host_id~=self.host_id then return fail(409,'Fleet host changed')end
  return self.receipts:run(b.client_id,b.command_seq,route..':'..json.encode(b),function()
    if route=='launch'then return self:_launch(b)end
    return self:_command(b)
  end)
end
function Host:close()
  if self.closed then return end;self.closed=true
  self.registry:watch(self.channel,nil);self.async:close();self.server:close_streams(self.channel)
  for _,s in pairs(self.sessions)do
    self:_release_observation(s)
    if s.workers then s.workers:close('server stopped',true)end
    if self.registry.agents[s.rec.id]==s.rec then self.registry:retire(s.rec.id,s.rec.generation,ended[s.rec.state]and s.rec.state or 'stopped')end
  end
  self.sessions={}
end
return M
