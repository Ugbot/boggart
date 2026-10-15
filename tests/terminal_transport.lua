local T=require 'terminal.transport';local uv=require 'uv'
local function response(body,extra)return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '..#body..'\r\n'..(extra or '')..'\r\n'..body end
local count,received=0
local parser=T.parser(false,nil,function(status,body)assert(status==200);count=count+1;received=body end)
for c in response('{"emoji":"🦊"}'):gmatch('.')do parser:feed(c)end
assert(count==1 and received=='{"emoji":"🦊"}');parser:eof()
local events={};local stream=T.parser(true,function(event,body)events[#events+1]={event,body}end,function()error('stream completed')end)
local bytes='HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n: hello\r\n\r\nevent: message\r\ndata: first\r\ndata: second\r\n\r\ndata: tail\n\n'
for c in bytes:gmatch('.')do stream:feed(c)end
assert(#events==2 and events[1][1]=='message' and events[1][2]=='first\nsecond' and events[2][2]=='tail')
local function rejects(bytes,sse,eof)
  local p=T.parser(sse,function()end,function()end)
  local ok=pcall(function()p:feed(bytes);if eof then p:eof()end end);assert(not ok,'malformed response accepted')
end
rejects(response('{}','Content-Length: 2\r\n'))
rejects(response('{}','Transfer-Encoding: chunked\r\n'))
rejects(response('{}','Content-Encoding: gzip\r\n'))
rejects((response('{}'):gsub('application/json','application/jsonp')))
rejects(response('{}')..'junk')
rejects(response('{}'):sub(1,-2),false,true)
rejects('HTTP/1.1 200 OK\r\nX: '..string.rep('x',T.MAX_HEADERS))
rejects('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 99999999\r\n\r\n')
rejects('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: '..string.rep('x',T.MAX_BODY+4097),true)
if package.config:sub(1,1)=='\\'then return 0 end
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-transport-XXXXXX'));local socket=dir..'/sock'
local listener=uv.new_pipe(false);assert(listener:bind(socket));local peers={}
assert(listener:listen(16,function(error)
  assert(not error);local peer=uv.new_pipe(false);listener:accept(peer);peers[#peers+1]=peer
end))
local function await(check)
  local deadline=uv.hrtime()+2e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('transport test deadline')
end
local calls=0
local op=T.request({socket=socket,path='/idle',method='GET',timeout_ms=15},function(why)assert(why.kind=='timeout');calls=calls+1 end)
await(function()return op.done end);assert(calls==1 and op.pipe:is_closing() and op.timer:is_closing())
local cancel=T.request({socket=socket,path='/idle',method='GET'},function(why)assert(why.kind=='cancelled');calls=calls+1 end)
cancel:cancel();cancel:cancel();uv.run('nowait');assert(calls==2)
for _,peer in ipairs(peers)do if not peer:is_closing()then peer:close()end end
listener:close();uv.run('nowait');uv.fs_unlink(socket);assert(uv.fs_rmdir(dir))
print('terminal_transport: fragmented JSON/SSE, strict bounded framing, truncation, deadlines and cancellation pass')
return 0
