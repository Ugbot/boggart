-- Launch actual Boggart TUI plus foreign process fixtures into one real Fleet.
local ok,err=xpcall(function()
  local core=require 'core';local shell=require 'shell';local launcher=require 'core.agentlauncher'
  require('core.config').bmux_server=false -- this fixture tests the local agent Fleet
  local registry=require('core.fleetagents').registry;local dash=require 'dash'
  local function frame(n)
    for _=1,n or 2 do core.redraw=true;core.frame_start=system.get_time();core.step();registry:poll()end
  end
  local function until_true(check)
    local deadline=system.get_time()+8
    repeat frame(1);if check()then return end;system.wait_event(0.02)until system.get_time()>deadline
    error('agent process deadline')
  end
  local function text(view)
    view:sync(true);local rows={}
    for y=1,view.rows do
      local line={};for _,cell in ipairs(view.terminal:row(y).cells)do line[#line+1]=cell.text end
      rows[#rows+1]=table.concat(line)
    end
    return table.concat(rows,'\n')
  end
  local function click(view,label)
    frame(3);local hit
    for _,r in ipairs(view.hits)do if r.item.label==label then hit=r;break end end
    assert(hit,'working Fleet control '..label)
    core.on_event('mousepressed','left',hit.x+hit.w/2,hit.y+hit.h/2,1)
    core.on_event('mousereleased','left',hit.x+hit.w/2,hit.y+hit.h/2,1);frame()
  end
  local count=#registry.order
  for _,profile in ipairs{{cmd='/bin/sh\0wrong'}, {cmd='/bin/sh',args={false}}, {cmd='/bin/sh',args={extra='wrong'}}}do
    assert(not pcall(launcher.launch,profile),'invalid argv rejected before registration/spawn')
  end
  assert(#registry.order==count)
  -- Use the application's launcher, not a substitute TUI or mocked terminal.
  shell.switch('bmux');frame(3)
  local toolbar=require('shell.workspaces.bmux').toolbar;local new_agent
  for _,r in ipairs(toolbar.hits)do if r.item.command=='bmux:new-agent' then new_agent=r end end
  assert(new_agent,'visible New agent control')
  core.on_event('mousepressed','left',new_agent.x+new_agent.w/2,new_agent.y+new_agent.h/2,1)
  core.on_event('mousereleased','left',new_agent.x+new_agent.w/2,new_agent.y+new_agent.h/2,1);frame()
  system._test_event{type='textinput',text='Boggart TUI'}
  system._test_event{type='keypressed',key='Return'};system._test_event{type='keyreleased',key='Return'};frame(3)
  local native_view=core.active_view
  local native=assert(registry.agents[native_view.fleet_agent_id],'chooser launches and registers agent')
  assert(native.provider=='boggart' and native_view.custom_title=='Boggart TUI',
    'chooser selected provider='..tostring(native.provider)..' title='..tostring(native_view.custom_title))
  until_true(function()return native_view.state and native_view.state.alternate and text(native_view):find('ctx ',1,true)end)
  local ready,why=pcall(until_true,function()return native.state=='idle' and native.session_id and native.capabilities.prompt end)
  assert(ready,tostring(why)..'\n'..require('json').encode(native)..'\n'..text(native_view)..'\n'..require('json').encode(native_view.terminal:channel():state()))
  assert(native.pid>0,'actual Boggart TUI is tracked')
  system._test_event{type='textinput',text='/quit'}
  system._test_event{type='keypressed',key='Return'};system._test_event{type='keyreleased',key='Return'}
  until_true(function()return native.state=='exited'end)
  assert(native.exit_status==0 and text(native_view):find('saved. resume this session:',1,true),'TUI keyboard quit persists a real session')
  local sid=text(native_view):match('%-%-resume%s+(%d+)');assert(sid,'real saved session ID')
  local resumed,resumed_view=launcher.boggart(sid)
  until_true(function()return resumed_view.state and resumed_view.state.alternate end)
  assert(tostring(resumed.session_id)==sid and resumed.id~=native.id,'resume is a new runtime with the saved conversation reference')
  local existing=launcher.boggart(sid);assert(existing==resumed,'known live resumed session focuses rather than launching again')
  assert(registry:control(resumed.id,resumed.generation,'stop'));assert(resumed.state=='stopped')

  local foreign,view=launcher.launch{provider='fixture-foreign',name='Foreign TUI',cmd='/bin/sh',args={'-c',[[stty -echo; printf 'FOREIGN_READY\r\n'; IFS= read -r line; printf '\r\nFOREIGN:%s\r\n' "$line"; exit 7]]}}
  until_true(function()return text(view):find('FOREIGN_READY',1,true)end)
  assert(foreign.state=='alive' and foreign.capabilities.focus and foreign.capabilities.stop)
  assert(not foreign.capabilities.approve and not registry:control(foreign.id,foreign.generation,'approve'),'no invented provider approvals')
  local internal=dash.touch(900001);internal.kind='internal fixture'
  shell.switch('fleet');frame(3)
  local fleet=require('core.swarmview').ensure();fleet.selected=foreign.id;frame(3)
  local found_internal,found_foreign=false,false
  for _,rec in ipairs(fleet:records())do found_internal=found_internal or rec==internal;found_foreign=found_foreign or rec==foreign end
  assert(found_internal and found_foreign,'the existing Fleet has both providers')
  click(fleet,'Focus pane');assert(shell.current=='bmux' and core.active_view==view,'Fleet focuses the original native pane')
  local pid=foreign.pid
  assert(not registry:control(foreign.id,foreign.generation+1,'stop') and foreign.state=='alive','stale action is rejected')
  shell.switch('edit');frame()
  view:send('payload\n');until_true(function()return foreign.state=='failed'end)
  assert(foreign.exit_status==7 and foreign.pid==pid,'hidden process exit is authoritative')
  shell.switch('fleet');fleet.selected=foreign.id;frame(3)
  assert(fleet:state_of(foreign)=='failed' and not foreign.capabilities.stop and foreign.capabilities.focus)
  assert(registry:control(foreign.id,foreign.generation,'focus'));assert(text(view):find('FOREIGN:payload',1,true),'final native output remains available')
  view:try_close(function()end);assert(not foreign.capabilities.focus,'closed pane retires callbacks')

  local stopped,stopped_view=launcher.launch{provider='custom',name='Waiting agent',cmd='/bin/sh',args={'-c','IFS= read -r line'}}
  until_true(function()return stopped.state=='alive'end)
  shell.switch('fleet');fleet.selected=stopped.id;frame(3);click(fleet,'Stop')
  assert(shell.current=='fleet' and stopped.state=='stopped' and stopped_view.terminal==nil,'Fleet Stop does not steal workspace focus')
  local failed,failed_view=launcher.launch{provider='custom',name='Missing agent',cmd='/not/a/real/agent'}
  assert(failed.state=='failed' and failed.error and failed_view.spawn_error,'failed launches remain visible')
  local literal,literal_view=launcher.launch{provider='custom',name='Literal argv',cmd='/usr/bin/printf',args={'%s','literal $HOME `nothing` "quote";'}}
  until_true(function()return literal.state=='exited'end)
  assert(text(literal_view):find('literal $HOME `nothing` "quote";',1,true),'arguments are delivered literally without shell expansion')
  print('Fleet agents: actual Boggart TUI/keyboard quit/resume, foreign PTY, one internal/external roster, focus/stop/stale control, hidden exit and failed launch pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
