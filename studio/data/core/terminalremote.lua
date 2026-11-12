-- Studio adds its native image; transport, leases and input policy are shared.
local Remote=require 'terminal.remote'
return {new=function(opts,changed)
  return Remote.new(opts,changed,renderer.terminal_image())
end}
