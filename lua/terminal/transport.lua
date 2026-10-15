-- Native control-server HTTP subset over libuv UDS, with bounded framing.
local uv=require 'uv'
local M={MAX_BODY=4*1024*1024,MAX_HEADERS=16384}
local Parser={};Parser.__index=Parser
local function fail(message)return error(message,0)end
function M.parser(stream,emit,complete,ready)
  return setmetatable({stream=stream,emit=emit,complete=complete,ready=ready,buffer='',event_bytes=0,data={}},Parser)
end
function Parser:feed(chunk)
  if self.done then return end
  self.buffer=self.buffer..chunk
  if not self.headers then
    local at=self.buffer:find('\r\n\r\n',1,true)
    if not at then if #self.buffer>M.MAX_HEADERS then fail('response headers too large')end;return end
    if at+3>M.MAX_HEADERS then fail('response headers too large')end
    local head=self.buffer:sub(1,at-1);self.buffer=self.buffer:sub(at+4)
    local status,rest=head:match('^HTTP/1%.[01] (%d%d%d) [^\r\n]*\r\n(.*)$')
    if not status then fail('invalid HTTP response')end
    self.status=tonumber(status);local headers={}
    for line in (rest..'\r\n'):gmatch('(.-)\r\n')do
      local key,value=line:match('^([%w-]+):[ \t]*(.-)[ \t]*$')
      if not key or value:find('[%z\1-\8\10-\31\127]')then fail('invalid response header')end
      key=key:lower();if headers[key]then fail('duplicate response header')end;headers[key]=value
    end
    if headers['transfer-encoding'] or headers['content-encoding']then fail('unsupported response encoding')end
    local length=headers['content-length'];local content=(headers['content-type'] or ''):lower()
    self.streaming=self.stream and self.status==200
    if self.streaming then
      if length or not content:match('^text/event%-stream[; ]*$')then fail('invalid SSE response')end
    else
      if not length or not length:match('^%d+$') or #length>10 then fail('invalid response length')end
      self.length=tonumber(length);if self.length>M.MAX_BODY then fail('response body too large')end
      if self.status>=200 and self.status<300 and content~='application/json' and not content:match('^application/json%s*;')then fail('expected JSON response')end
    end
    self.headers=headers
    if self.ready then self.ready(self.status,headers)end
  end
  if not self.streaming then
    if #self.buffer>self.length then fail('bytes after response body')end
    if #self.buffer==self.length then self.done=true;self.complete(self.status,self.buffer);self.buffer=''end
    return
  end
  while not self.done do
    local at=self.buffer:find('\n',1,true)
    if not at then break end
    local line=self.buffer:sub(1,at-1):gsub('\r$','');self.buffer=self.buffer:sub(at+1)
    self.event_bytes=self.event_bytes+at
    if self.event_bytes>M.MAX_BODY+4096 then fail('SSE event too large')end
    if line==''then
      if #self.data>0 then
        local payload=table.concat(self.data,'\n')
        if #payload>M.MAX_BODY then fail('SSE data too large')end
        local event=self.event or 'message';self.data={};self.event=nil;self.event_bytes=0
        self.emit(event,payload)
      else self.event=nil;self.event_bytes=0 end
    elseif line:sub(1,1)~=':'then
      local key,value=line:match('^([^:]+): ?(.*)$')
      if key=='data'then self.data[#self.data+1]=value
      elseif key=='event'then if #value>128 or value:find('[%z\1-\31\127]')then fail('invalid SSE event name')end;self.event=value end
    end
  end
  if #self.buffer+self.event_bytes>M.MAX_BODY+4096 then fail('SSE event too large')end
end
function Parser:eof()
  if not self.done then fail(self.streaming and 'stream disconnected' or 'truncated HTTP response')end
end
local function close(handle)
  if handle and not handle:is_closing()then handle:close()end
end
local Operation={};Operation.__index=Operation
function Operation:finish(why,body,status)
  if self.done then return end
  self.done=true;self.error=why
  if self.parser then self.parser.done=true;self.parser.buffer='';self.parser.data={}end
  close(self.timer);close(self.pipe)
  local callback=self.callback;self.callback=nil
  if callback then local ok,err=pcall(callback,why,body,status);if not ok then self.callback_error=tostring(err):sub(1,256)end end
end
function Operation:cancel()self:finish({kind='cancelled',message='request cancelled'})end
local function guarded(op,fn,...)
  if op.done then return end
  local ok,why=pcall(fn,...)
  if not ok then op:finish({kind='protocol',message=tostring(why):sub(1,256)})end
end
function M.request(opts,callback)
  assert(type(callback)=='function','request callback required')
  assert(type(opts.socket)=='string' and opts.socket:sub(1,1)=='/' and #opts.socket<=91 and not opts.socket:find('%z'),'invalid UDS path')
  assert(opts.method=='GET' or opts.method=='POST','unsupported control method')
  assert(type(opts.path)=='string' and #opts.path<=4096 and opts.path:match('^/[%w_/%-?=&]*$'),'invalid control path')
  assert(opts.body==nil or type(opts.body)=='string' and #opts.body<=M.MAX_BODY,'invalid request body')
  assert(opts.token==nil or type(opts.token)=='string' and #opts.token>0 and #opts.token<=4096 and not opts.token:find('[%z\1-\32\127]'),'invalid bearer token')
  local timeout=opts.timeout_ms or 5000
  assert(type(timeout)=='number' and timeout%1==0 and timeout>=1 and timeout<=60000,'invalid request deadline')
  local op=setmetatable({pipe=uv.new_pipe(false),timer=uv.new_timer(),callback=callback},Operation)
  op.parser=M.parser(opts.stream,function(event,data)
    if op.done then return end
    if opts.on_event then opts.on_event(event,data)end
    if op.timer then close(op.timer);op.timer=nil end -- only first complete event, not headers/comments
  end,function(status,body)op:finish(nil,body,status)end,opts.on_headers)
  op.timer:start(timeout,0,function()op:finish({kind='timeout',message='control request deadline exceeded'})end)
  guarded(op,function()
    op.pipe:connect(opts.socket,function(why)
      if op.done then return end
      if why then op:finish({kind='transport',message='control socket connect failed'});return end
      guarded(op,function()
        -- Grow small Unix socket buffers at both ends; keep larger OS/user
        -- settings. Refusal is only a missed performance hint, not an error.
        local receive=op.pipe:recv_buffer_size()
        if receive and receive<256*1024 then op.pipe:recv_buffer_size(256*1024)end
        local send=op.pipe:send_buffer_size()
        if send and send<256*1024 then op.pipe:send_buffer_size(256*1024)end
        assert(op.pipe:read_start(function(error,data)
          if op.done then return end
          if error then op:finish({kind='transport',message='control socket read failed'})
          elseif data then guarded(op,op.parser.feed,op.parser,data)
          else guarded(op,op.parser.eof,op.parser)end
        end))
        local body=opts.body or ''
        local request=opts.method..' '..opts.path..' HTTP/1.1\r\nHost: localhost\r\n'
          ..(opts.token and 'Authorization: Bearer '..opts.token..'\r\n' or '')
          ..'Content-Type: application/json\r\nContent-Length: '..#body..'\r\n\r\n'..body
        assert(op.pipe:write(request,function(error)
          if error then op:finish({kind='transport',message='control socket write failed'})end
        end))
      end)
    end)
  end)
  return op
end
return M
