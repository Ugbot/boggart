local Fleet=require 'fleet';local argv=require 'agentargv'
local r=Fleet.new{prefix='fixture',max_records=2}
local internal={id=7,kind='worker',bytes=0}
r:set_source('boggart',function()return {internal}end)
local agent=r:register{provider='foreign',name='Foreign TUI'};local focus,stop=0,0
r:bind(agent.id,1,{poll=function()return {state='alive',pid=123,activity='activity unknown'}end,
  focus=function()focus=focus+1;return true end,stop=function()stop=stop+1;return true end})
r:poll();assert(agent.state=='alive' and agent.pid==123)
assert(not pcall(function()r:bind(agent.id,1,{})end),'one runtime cannot acquire a second execution adapter')
assert(not pcall(function()r:retire(agent.id,1,'alive')end),'released ownership cannot retain a live state')
local rows=r:records();assert(rows[1]==internal and rows[2]==agent,'one roster holds internal and foreign agents')
assert(r:control(agent.id,1,'focus') and focus==1)
assert(not r:control(agent.id,2,'stop') and stop==0,'stale generation cannot control process')
assert(not r:control(agent.id,1,'approve'),'unsupported semantic controls are rejected')
r:retire(agent.id,1,'stopped');assert(not r:control(agent.id,1,'focus'))
local second=r:register{provider='boggart',name='Boggart TUI'}
local third=r:register{provider='custom',name='Custom'}
assert(second.id~=third.id and not r.agents[agent.id],'retirement evicts only released history')
assert(not pcall(function()r:register{name='overflow'}end),'live records cannot be evicted')
local args=argv.parse([[tool 'two words' "" escaped\ space '$HOME' "a\b" `literal`]])
assert(#args==7 and args[2]=='two words' and args[3]=='' and args[4]=='escaped space' and args[5]=='$HOME' and args[6]=='a\\b' and args[7]=='`literal`')
for _,text in ipairs{'',"tool 'oops",'tool \\', 'tool\0x'}do assert(not pcall(argv.parse,text))end
print('Fleet: common sources, external identity/capabilities, stale control, bounded retirement and literal argv pass')
return 0
