local uv=require 'uv'
local server=assert(serve.listen{socket=assert(os.getenv('BOGGART_TEST_SOCKET')),handler=function()return 200,'{}'end})
local timer=uv.new_timer();timer:start(1000,1000,function()end)
uv.run()
server:stop();timer:stop();timer:close()
return 0
