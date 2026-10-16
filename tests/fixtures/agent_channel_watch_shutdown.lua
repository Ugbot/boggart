local t=assert(require('terminal').open{cmd='/bin/sh',args={'-c','sleep 30'},control=true})
rawset(_G,'retained_channel_terminal',t)
t:channel():watch(function()
  local marker=assert(io.open(boggart.args[1],'w'));marker:write('BAD_CALLBACK');marker:close()
end)
return 0
