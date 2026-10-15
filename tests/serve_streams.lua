if package.config:sub(1,1)=='\\'then return end
local uv=require 'uv'
local directory=assert(uv.fs_mkdtemp('/tmp/bmux-streams-XXXXXX'));local path=directory..'/control.sock'
local server=coroutine.wrap(function()return assert(serve.listen{socket=path,handler=function(req)
  if req.path=='/global'then return 'stream'end
  if req.path=='/private'then return 'stream','private','{"initial":true}'end
  if req.path=='/slow'then return 'stream','slow'end
  if req.path=='/invalid'then return 'stream','bad\nchannel'end
  return 404,'{}'
end})end)()
collectgarbage('collect');collectgarbage('collect')
local function await(check)
  local deadline=uv.hrtime()+5e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('SSE stream deadline')
end
local function connect(route)
  local client={pipe=uv.new_pipe(false),data='',closed=false}
  client.pipe:connect(path,function(error)
    assert(not error,error)
    client.pipe:read_start(function(why,data)
      assert(not why,why)
      if data then client.data=client.data..data else client.closed=true;client.pipe:close()end
    end)
    client.pipe:write('GET '..route..' HTTP/1.1\r\nHost: localhost\r\n\r\n')
  end)
  await(function()return client.data:find('\r\n\r\n',1,true)end)
  return client
end
local public=connect('/global');local private=connect('/private')
await(function()return private.data:find('"initial":true',1,true)end)
assert(server:clients()==2 and server:clients('private')==1)
assert(server:broadcast('private-event','PRIVATE_PAYLOAD','private')==1)
assert(server:broadcast('global-event','GLOBAL_PAYLOAD')==1)
await(function()return private.data:find('PRIVATE_PAYLOAD',1,true) and public.data:find('GLOBAL_PAYLOAD',1,true)end)
assert(not public.data:find('PRIVATE_PAYLOAD',1,true) and not private.data:find('GLOBAL_PAYLOAD',1,true),'global and targeted streams are isolated')
assert(not pcall(server.broadcast,server,'bad\nevent','x') and not pcall(server.broadcast,server,'valid','x','bad\nchannel'))
assert(not pcall(server.clients,server,'private\0other') and not pcall(server.close_streams,server,'private\0other'),'selectors cannot truncate a channel at NUL')
private.pipe:close();await(function()return server:clients('private')==0 end)
assert(server:clients()==1,'idle peer EOF is detected without another broadcast')
local again=connect('/private');assert(server:close_streams('private')==1)
await(function()return again.closed end);assert(server:clients()==1)
local slow=connect('/slow');slow.pipe:read_stop()
local payload=string.rep('x',4*1024*1024)
assert(server:broadcast('large',payload,'slow')==1,'one maximum attachment frame fits')
server:broadcast('large',payload,'slow');server:broadcast('large',payload,'slow')
assert(server:clients('slow')==0,'slow consumer closes at bounded queued writes')
slow.pipe:close();uv.run('nowait')
local invalid=connect('/invalid');await(function()return invalid.closed end)
assert(invalid.data:find('500',1,true) and not invalid.data:find('text/event-stream',1,true),'malformed channel is rejected before upgrade')
assert(server:close_streams()==1);await(function()return public.closed end)
server:stop();uv.run('nowait');assert(uv.fs_rmdir(directory))
print('serve_streams: targeted/global isolation, initial replay, idle disconnect, invalid channels, large frames and bounded backpressure pass')
return 0
