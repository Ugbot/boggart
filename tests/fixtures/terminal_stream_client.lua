-- A bounded independent replica for real HTTP/SSE integration tests.
local uv=require 'uv';local json=require 'json';local M={};local Client={};Client.__index=Client
function Client:apply(frame)
  if not frame.cursor then return end
  local view=self.view
  if frame.cursor<=view.cursor then return end -- immutable retry/duplicate
  assert(frame.after==view.cursor,'gap in terminal push cursors')
  if frame.kind=='snapshot'then view.screen=frame.screen
  else for _,change in ipairs(frame.changes or {})do view.screen[change.index]=change.row end end
  if frame.scrollback then view.scrollback=frame.scrollback end
  view.cursor=frame.cursor;view.cols=frame.cols;view.rows=frame.rows;view.state=frame.state;view.process=frame.process
end
function Client:read(data)
  self.buffer=self.buffer..data;assert(#self.buffer<=8*1024*1024,'test stream buffer overflow')
  if not self.status then
    local boundary=self.buffer:find('\r\n\r\n',1,true);if not boundary then return end
    self.status=tonumber(self.buffer:match('^HTTP/[%d.]+%s+(%d+)'))
    self.buffer=self.buffer:sub(boundary+4)
  end
  while true do
    local boundary=self.buffer:find('\n\n',1,true);if not boundary then return end
    local block=self.buffer:sub(1,boundary-1);self.buffer=self.buffer:sub(boundary+2)
    local event=block:match('event: ([^\n]+)');local payload=block:match('data: ([^\n]+)')
    if event and payload then
      local decoded=json.decode(payload);self.events[#self.events+1]={event=event,data=decoded}
      assert(#self.events<=256,'test event history overflow')
      if event=='message' and decoded.v==1 and decoded.cursor then self:apply(decoded)end
    end
  end
end
function Client:close()
  if not self.pipe:is_closing()then self.pipe:close()end;self.closed=true
end
function M.connect(socket,path,body,snapshot)
  local client=setmetatable({pipe=uv.new_pipe(false),buffer='',events={},view={cursor=0,screen={}}},Client)
  if snapshot then client:apply(snapshot)end
  local encoded=body and json.encode(body)
  client.pipe:connect(socket,function(error)
    assert(not error,error)
    client.pipe:read_start(function(why,data)
      if data then client:read(data)else client.error=why;client:close()end
    end)
    client.pipe:write((body and 'POST ' or 'GET ')..path..' HTTP/1.1\r\nHost: localhost\r\n'
      ..(body and 'Content-Type: application/json\r\nContent-Length: '..#encoded..'\r\n' or '')..'\r\n'..(encoded or ''))
  end)
  return client
end
return M
