local uv=require 'uv';local calls=0
local t=coroutine.wrap(function()
  local owner=require('terminal').new()
  owner:watch(function(value)assert(value==owner);calls=calls+1 end)
  return owner
end)()
collectgarbage('collect');collectgarbage('collect')
t:feed('coroutine owner survived');uv.run('nowait')
assert(calls==1,'callback survives collection of the creating coroutine')
t:close();uv.run('nowait')
print('terminal watch coroutine lifetime passes')
return 0
