local t=require('terminal').new();rawset(_G,'retained_watch',t)
t:watch(function()error('callback during interpreter teardown')end)
return 0
