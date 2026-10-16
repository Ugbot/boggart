-- Deliberately return with a connect and its timer still pending. No manual
-- uv.run/cancel/drain: the executable's teardown owns this lifecycle boundary.
if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local T=require 'terminal.transport'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-exit-XXXXXX'));local socket=dir..'/sock'
local listener=uv.new_pipe(false);assert(listener:bind(socket));assert(listener:listen(8,function()end))
T.request({socket=socket,method='GET',path='/pending'},function()end)
if package.loaded.core then package.loaded.core.quit(true)end
print('Returning to native teardown with a pending control connect/timer')
return 0
