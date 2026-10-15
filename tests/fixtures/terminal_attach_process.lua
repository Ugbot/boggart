-- Independent real client, deliberately killed by terminal_client.lua.
local uv=require 'uv';local json=require 'json';local Client=require 'terminal.client'
local started=uv.hrtime();local client=Client.new{socket=assert(os.getenv('BMUX_ATTACH_SOCKET'))}
client:attach(assert(os.getenv('BMUX_ATTACH_ID')),1,{tail=32},function(why,session)
  assert(not why,why and why.message)
  local elapsed=(uv.hrtime()-started)/1e6;local view=session:view()
  local path=assert(os.getenv('BMUX_ATTACH_READY'));local file=assert(io.open(path..'.tmp','wb'))
  file:write(json.encode{elapsed_ms=elapsed,pid=view.process.pid,screen=view.screen,scrollback=view.scrollback});file:close()
  assert(uv.fs_rename(path..'.tmp',path))
end)
uv.run()
return 0
