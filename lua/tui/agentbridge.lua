-- Semantic control of this TUI's existing coordinator. No terminal-text parsing
-- or synthetic keys: the event loop calls poll after draining human input.
local json=require 'json'
local M={};local Bridge={};Bridge.__index=Bridge
local function text(s,max)
  return type(s)=='string' and #s>0 and #s<=max and not s:find('\0',1,true) and utf8.len(s)~=nil
end
function M.new(st,channel)
  if not channel then return nil end
  return setmetatable({st=st,channel=channel,revision=0,draft=st.box.line or '',
    session=st.coord.session,session_id=st.coord.session.id,serial=0,state_serial=0},Bridge)
end
function M.attach(st)
  local channel=require('agent_channel').adopt_env()
  return M.new(st,channel)
end
function Bridge:observe()
  local st=self.st;local draft=st.box.line or '';local session=st.coord.session
  if draft~=self.draft or session~=self.session or session.id~=self.session_id then
    self.draft,self.session,self.session_id=draft,session,session.id;self.revision=self.revision+1
  end
  local pending=st.pending and st.pending.decision==nil and st.pending or nil
  if pending~=self.pending then
    self.pending=pending;self.serial=self.serial+1
    self.request_id=pending and ('approval:'..self.serial) or nil
  end
end
function Bridge:send(value)
  value.v=1;value.id=self.id;value.generation=self.generation
  local ok,bytes=pcall(json.encode,value)
  if not ok or #bytes>65536 then self.channel:close();return nil end
  local sent=self.channel:send(bytes);if not sent then self.channel:close()end;return sent
end
function Bridge:publish()
  if not self.id then return end
  self:observe();local st=self.st
  local phase=self.pending and 'waiting_for_approval' or bog.choice and 'waiting_for_answer'
    or (st.running or self.prompt) and 'running' or 'idle'
  local value={type='state',session_id=st.coord.session.id,model=st.coord.session.model,
    state=phase,input_revision=self.revision,draft_bytes=#self.draft,
    capabilities={prompt=true,interrupt=st.running==true,approve=self.pending~=nil,worker_stop=self.workers~=nil}}
  if self.pending then
    value.request={id=self.request_id,kind='approval',name=tostring(self.pending.name or ''):sub(1,256),
      summary=tostring(self.pending.summary or ''):sub(1,2048)}
  end
  local signature=json.encode(value)
  if signature~=self.signature then
    self.signature=signature;self.state_serial=self.state_serial+1;value.sequence=self.state_serial;self:send(value)
  end
  if self.workers then
    local ok,error=self.workers:poll(function(message)return self:send(message)end)
    if not ok then self.channel:close();self.worker_error=error end
  end
end
function Bridge:command(cmd)
  local st=self.st
  if cmd.id~=self.id or cmd.generation~=self.generation then return nil,'stale runtime' end
  if type(cmd.command_seq)~='number' or cmd.command_seq%1~=0 or cmd.command_seq<1
    or cmd.command_seq>9007199254740991 or cmd.command_seq<=(self.command_seq or 0) then return nil,'replayed command' end
  self.command_seq=cmd.command_seq
  if cmd.action=='prompt' then
    if cmd.input_revision~=self.revision then return nil,'draft changed' end
    if #self.draft>0 or st.help or bog.choice or self.pending or st.voice or st.ptt_rec or self.prompt then return nil,'human input or dialog owns the session' end
    if not text(cmd.text,16384) or not cmd.text:match('%S') then return nil,'invalid prompt' end
    if st.running then
      st.coord.session.inbox=st.coord.session.inbox or {}
      local bytes=0;for _,value in ipairs(st.coord.session.inbox)do bytes=bytes+#value end
      if #st.coord.session.inbox>=32 or bytes+#cmd.text>262144 then return nil,'steering inbox full' end
      st.coord.session.inbox[#st.coord.session.inbox+1]=cmd.text
      st.entries[#st.entries+1]={role='user',text=cmd.text};st.cur,st.think=nil,nil;st.dirty=true
    else self.prompt=cmd.text end
    return true
  elseif cmd.action=='interrupt' then
    if not st.running then return nil,'no active turn' end
    st.abort=true;return true
  elseif cmd.action=='worker_stop' then
    if not self.workers then return nil,'worker control is unavailable'end
    return self.workers:stop(cmd.worker_session_id,cmd.worker_incarnation)
  elseif cmd.action=='approve' then
    if not self.pending or cmd.request_id~=self.request_id then return nil,'stale approval request' end
    if cmd.decision~='approve' and cmd.decision~='reject' then return nil,'invalid approval decision' end
    self.pending.decision=cmd.decision;st.dirty=true;return true
  end
  return nil,'unsupported command'
end
function Bridge:poll()
  self:observe()
  for _=1,64 do
    local bytes=self.channel:receive();if not bytes then break end
    local ok,cmd=pcall(json.decode,bytes)
    if not ok or type(cmd)~='table' or cmd.v~=1 then self.channel:close();break end
    if not self.id and cmd.type=='bind' and text(cmd.id,128) and type(cmd.generation)=='number'
      and cmd.generation%1==0 and cmd.generation>=1 then
      self.id,self.generation=cmd.id,cmd.generation
      if type(cmd.features)=='table' and cmd.features.workers==true then self.workers=require('tui.fleetworkers').new(self.st)end
    elseif self.id and cmd.type=='command' and text(cmd.command_id,128) then
      local accepted,error=self:command(cmd)
      self:send{type='result',command_id=cmd.command_id,accepted=accepted==true,error=error}
      self:observe()
    else self.channel:close();break end
  end
  self:publish()
end
function Bridge:take_prompt()local prompt=self.prompt;self.prompt=nil;return prompt end
function Bridge:close()if self.workers then self.workers:close()end;self.channel:close()end
return M
