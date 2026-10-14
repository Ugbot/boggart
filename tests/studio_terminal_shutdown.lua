local core=require 'core'
local View=require 'core.terminalview'
local view=View{cmd='/bin/sh',args={'-c','sleep 30'}}
core.root_view:get_active_node():add_view(view)
core.frame_start=system.get_time(); core.step()
assert(system.loop_stats().enabled and view.terminal:process_state().pid>0)
core.quit(true)
print('Studio returns to native teardown with a live PTY and blocked waiter')
