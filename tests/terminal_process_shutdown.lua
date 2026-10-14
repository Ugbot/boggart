-- Retain a live process through script return. The native application shutdown
-- must detach its core and retire raw handles before luv's loop finalizer.
local terminal=require'terminal'
if package.config:sub(1,1)=='\\' then return end
rawset(_G,'live_terminal_at_shutdown',assert(terminal.open{cmd='/bin/sh',args={'-c','sleep 30'}}))
assert(live_terminal_at_shutdown:process_state().pid>0)
print('retained terminal reaches application teardown')
