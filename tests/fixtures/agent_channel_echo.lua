local uv=require 'uv'
local c=assert(require('agent_channel').adopt_env())
local done=false
c:watch(function(owner)
  while true do
    local text=owner:receive();if not text then break end
    if text=='EXIT'then assert(owner:send('FINAL'));done=true
    else assert(owner:send(text))end
  end
  if owner:state().closed then done=true end
end)
assert(c:send('READY'))
while not done or c:state().queued_frames>0 do uv.run('once')end
c:close();uv.run('nowait')
return 0
