-- Product attachment sessions. The daemon alone owns the PTY and parser.
local uv=require 'uv';local json=require 'json'
local transport=require 'terminal.transport';local replica=require 'terminal.replica'
local M={};local Client={};Client.__index=Client;local Session={};Session.__index=Session
local function problem(kind,message,status)return {kind=kind,message=message,status=status}end
local function valid_id(id)return type(id)=='string' and #id<=128 and id:match('^[%w_-]+$')end
local function clock()return uv.hrtime()/1e9 end
local function private_socket(path)
  if type(path)~='string' or path:sub(1,1)~='/' or #path>91 or path:find('%z')then return false end
  local parent=path:match('^(.*)/[^/]+$');local sock=uv.fs_lstat(path);local dir=parent and uv.fs_lstat(parent)
  local uid=uv.getuid()
  return sock and dir and sock.type=='socket' and dir.type=='directory' and sock.uid==uid and dir.uid==uid
    and sock.mode&63==0 and dir.mode&63==0
end
function M.new(opts)
  assert(type(opts)=='table' and private_socket(opts.socket),'an owned private UDS and parent directory are required')
  local timeout=opts.timeout_ms or 5000
  assert(type(timeout)=='number' and timeout%1==0 and timeout>=1 and timeout<=60000,'invalid client deadline')
  if opts.token then assert(type(opts.token)=='string' and #opts.token>0 and #opts.token<=4096 and not opts.token:find('[%z\1-\32\127]'),'invalid bearer token')end
  return setmetatable({socket=opts.socket,token=opts.token,timeout_ms=timeout,requests={},sessions={},request_count=0,session_count=0},Client)
end
-- callback(error, decoded_object, HTTP_status). No redirect, proxy or fallback.
function Client:request(method,path,body,callback,stream)
  assert(type(callback)=='function','callback required')
  local req={done=false}
  function req:cancel()if self.operation then self.operation:cancel()end end
  if self.closed or self.request_count>=64 then req.done=true;callback(problem('closed','client closed or request limit reached'));return req end
  local encoded,encoding_error
  if body~=nil then
    local ok,value=pcall(function()return type(body)=='string' and body or json.encode(body)end)
    if ok then encoded=value else encoding_error=true end
  end
  if encoding_error then req.done=true;callback(problem('request','invalid control request body'));return req end
  self.requests[req]=true;self.request_count=self.request_count+1
  local function complete(why,raw,status)
    if req.done then return end;req.done=true;self.requests[req]=nil;self.request_count=self.request_count-1
    local value
    if not why then
      if status<200 or status>=300 then why=problem('http','control request refused',status)
      else value,why=replica.decode(raw)end
    end
    callback(why,value,status)
  end
  local ok,op=pcall(transport.request,{socket=self.socket,token=self.token,method=method,path=path,
    body=encoded,timeout_ms=self.timeout_ms,
    stream=stream~=nil,on_event=stream},complete)
  if ok then req.operation=op else complete(problem('request','invalid control request'))end
  return req
end
function Client:close()
  if self.closed then return end;self.closed=true
  for session in pairs(self.sessions)do session:close()end
  for request in pairs(self.requests)do request:cancel()end
end
local function notify(callback,...)if callback then callback(...)end end
function Session:_credentials()
  return {generation=self.generation,attachment_token=self.attachment_token}
end
-- Admission/encoding failures can complete synchronously. A slot marker keeps
-- a completion callback's next operation from being overwritten on return.
function Session:_post(slot,path,body,callback,stream)
  local marker={};self[slot]=marker;local request
  request=self.client:request('POST',path,body,function(...)
    if self[slot]==marker or self[slot]==request then self[slot]=nil end
    callback(...)
  end,stream)
  if self[slot]==marker then if request.done then self[slot]=nil else self[slot]=request end end
  return request
end
function Session:_stream(callback)
  self.epoch=self.epoch+1;local epoch=self.epoch;local first=true;self.status='connecting'
  local body=self:_credentials();body.after=self.replica.view.cursor
  return self:_post('stream',self.path..'/stream',body,function(why)
    if self.closed or self.epoch~=epoch then return end
    self.status='disconnected';self.error=why
    if first then first=false;notify(callback,why or problem('transport','stream ended before replay'))
    else notify(self.on_disconnect,why)end
  end,function(event,raw)
    if self.closed or self.epoch~=epoch then return end
    assert(event=='message','unexpected terminal stream event')
    local frame,why=replica.decode(raw);if not frame then error(why.message,0)end
    local changed,failure=self.replica:apply(frame);if changed==nil then error(failure.message,0)end
    self.status='live';self.error=nil
    if first then first=false;notify(callback,nil,self)end
    if changed and not self.closed then notify(self.on_update,self.replica.view)end
  end)
end
-- attach returns a cancellable Session immediately; callback fires after replay.
function Client:attach(id,generation,opts,callback)
  opts=opts or {};assert(valid_id(id),'invalid terminal id')
  assert(type(generation)=='number' and generation%1==0 and generation>=1 and generation<=9007199254740991,'invalid terminal generation')
  assert(type(callback)=='function','attach callback required')
  local session=setmetatable({client=self,id=id,generation=generation,base='/terminals/'..id,
    replica=replica.new(id,generation),epoch=0,sequence=0,on_update=opts.on_update,on_disconnect=opts.on_disconnect,status='attaching'},Session)
  if self.closed or self.session_count>=64 then session.closed=true;callback(problem('closed','client closed or session limit reached'));return session end
  self.sessions[session]=true;self.session_count=self.session_count+1
  session:_post('attach_request',session.base..'/attachments',{generation=generation,tail=opts.tail},function(why,frame)
    if session.closed or session.status=='disconnected' then return end
    if not why then
      if not valid_id(frame.attachment_id) or type(frame.attachment_token)~='string' or #frame.attachment_token<1 or #frame.attachment_token>128
        or type(frame.reader_seconds)~='number' or frame.reader_seconds<=0 or frame.reader_seconds>3600 then
        why=problem('protocol','invalid attachment credentials')
      else
        local changed;changed,why=session.replica:apply(frame)
        if changed==false then why=problem('protocol','attachment did not supply initial snapshot')end
      end
    end
    if why then session:close();callback(why);return end
    session.attachment_token=frame.attachment_token;session.attachment_id=frame.attachment_id
    session.path=session.base..'/attachments/'..frame.attachment_id
    if opts.stream==false then session.status='attached';callback(nil,session)
    else session:_stream(callback)end
  end)
  return session
end
function Session:view()return self.replica.view end -- views are borrowed, read-only
function Session:_stop_stream()
  self.epoch=self.epoch+1
  if self.stream then local stream=self.stream;self.stream=nil;stream:cancel()end
end
function Session:disconnect()
  if self.closed then return end
  self.status='disconnected';self:_stop_stream()
  if self.attach_request then local request=self.attach_request;self.attach_request=nil;request:cancel()end
end
function Session:reconnect(callback)
  assert(type(callback)=='function','reconnect callback required')
  if self.closed or not self.path or self.status~='disconnected'then callback(problem('state','session is not disconnected'));return end
  self:_stream(callback) -- unavailable cursors are explicit; caller chooses fresh attach
end
function Session:close()
  if self.closed then return end
  self.closed=true;self:_stop_stream();self.status='closed';self.controller=nil
  if self.attach_request then self.attach_request:cancel();self.attach_request=nil end
  if self.command_request then self.command_request:cancel();self.command_request=nil end
  if self.control_request then self.control_request:cancel();self.control_request=nil end
  if self.client.sessions[self]then self.client.sessions[self]=nil;self.client.session_count=self.client.session_count-1 end
end
function Session:detach(callback)
  callback=callback or function()end
  if self.closed or not self.path then self:close();callback(problem('state','session is not attached'));return end
  local path,body=self.path..'/detach',self:_credentials();self:close()
  return self.client:request('POST',path,body,callback)
end
function Session:control(takeover,callback)
  assert(type(callback)=='function','control callback required')
  if self.closed or not self.path or self.pending or self.control_request then callback(problem('state','control unavailable while closed or a command is pending'));return end
  local body=self:_credentials();body.takeover=takeover==true
  if self.controller then body.control_token=self.controller.token end
  return self:_post('control_request',self.path..'/control',body,function(why,result)
    if self.closed then return end
    if not why then
      if result.v~=1 or result.id~=self.id or result.generation~=self.generation or result.attachment_id~=self.attachment_id
        or type(result.control_token)~='string' or #result.control_token<1 or #result.control_token>128
        or type(result.lease_seconds)~='number' or result.lease_seconds<=0 or result.lease_seconds>3600 then
        why=problem('protocol','invalid controller response')
      else
        if not self.controller or self.controller.token~=result.control_token then self.sequence=0 end
        self.controller={token=result.control_token,seconds=result.lease_seconds,expires=clock()+result.lease_seconds}
      end
    end
    if why then self.controller=nil end
    callback(why,result)
  end)
end
function Session:_send(callback)
  local pending=self.pending
  return self:_post('command_request',self.base..'/'..pending.kind,pending.body,function(why,result,status)
    if self.closed then return end
    if not why then
      local valid=result.id==self.id and result.generation==self.generation
      if pending.event_count then
        local n=result.accepted_bytes
        valid=valid and result.accepted_events==pending.event_count and type(n)=='number' and n%1==0 and n>=0 and n<=65536
      elseif pending.kind=='input'then valid=valid and result.accepted_bytes==pending.bytes
      elseif pending.kind=='resize'then valid=valid and result.cols==pending.cols and result.rows==pending.rows end
      if not valid then why=problem('protocol','invalid terminal command acknowledgement')end
    end
    if not why then self.sequence=pending.sequence;self.pending=nil
      if self.controller then self.controller.expires=clock()+self.controller.seconds end
    elseif why.kind=='http' and status<500 and status~=408 then
      self.pending=nil;if status==403 or status==409 then self.controller=nil end
    end
    -- Other failures are uncertain. Keep the exact encoded body for retry.
    callback(why,result)
  end)
end
function Session:_command(kind,payload,callback)
  assert(type(callback)=='function','command callback required')
  if self.closed or (self.status~='live' and self.status~='attached') or not self.controller or self.controller.expires<=clock()
    or self.pending or self.control_request or self.sequence>=9007199254740991 then callback(problem('state','live controller required with no pending command'));return end
  local body=self:_credentials();body.attachment_id=self.attachment_id;body.control_token=self.controller.token;body.command_seq=self.sequence+1
  for key,value in pairs(payload)do body[key]=value end
  self.pending={kind=kind,sequence=body.command_seq,body=json.encode(body),bytes=payload.text and #payload.text,
    event_count=payload.events and #payload.events,cols=payload.cols,rows=payload.rows}
  return self:_send(callback)
end
function Session:input(text,callback)
  assert(type(text)=='string' and #text<=65536,'invalid terminal input')
  return self:_command('input',{text=text},callback)
end
function Session:resize(cols,rows,callback)
  assert(type(cols)=='number' and cols%1==0 and cols>=1 and cols<=4096 and type(rows)=='number' and rows%1==0 and rows>=1 and rows<=4096,'invalid terminal geometry')
  return self:_command('resize',{cols=cols,rows=rows},callback)
end
function Session:events(events,callback)
  assert(type(callback)=='function','events callback required')
  local valid,message=require('terminal.input').validate(events)
  if not valid then callback(problem('request',message));return end
  return self:_command('input',{events=events},callback)
end
function Session:retry(callback)
  assert(type(callback)=='function','retry callback required')
  if self.closed or not self.pending or self.command_request then callback(problem('state','no retryable command'));return end
  return self:_send(callback)
end
return M
