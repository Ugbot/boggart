if package.config:sub(1,1)=='\\' then return end
local terminal=require 'terminal';local uv=require 'uv'
for _,env in ipairs{
  {'MISSING'}, {'=value'}, {'BAD-KEY=value'}, {'1BAD=value'}, {'A=one','A=two'},
  {extra='KEY=value'}, {[2]='KEY=value'}, {'A=\0'}, {string.rep('A',129)..'=value'},
  {'KEY='..string.rep('x',65536)},
}do assert(not pcall(terminal.open,{cmd='/bin/sh',args={'-c','exit'},env=env}),'invalid environment rejected')end
local child=assert(terminal.open{cmd='/bin/sh',args={'-c',[[printf '%s|%s|%s|%s|%s' "$BMUX_TEST_LITERAL" "$TERM" "$COLORTERM" "$BOGGART_AGENT_CHANNEL_FD" "$BMUX_TEST_EMPTY"]]},
  env={'BMUX_TEST_LITERAL=$HOME $(literal) 🦊','BMUX_TEST_EMPTY=','TERM=wrong','COLORTERM=wrong','BOGGART_AGENT_CHANNEL_FD=99'}})
local deadline=uv.new_timer();deadline:start(4000,0,function()error('environment fixture deadline')end);deadline:unref()
uv.run();deadline:stop();deadline:close();uv.run('nowait')
local state=child:process_state();assert(state.exited and state.exit_status==0)
local cells={};for _,cell in ipairs(child:row(1).cells)do cells[#cells+1]=cell.text end
assert(table.concat(cells):find('$HOME $(literal) 🦊|xterm-256color|truecolor||',1,true),'literal environment overrides with protected terminal/channel variables')
child:close();uv.run('nowait')
print('terminal_environment: dense unique bounded overrides, literal UTF-8 and protected native variables pass')
return 0
