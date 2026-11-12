-- Real SDL event routing, real native TUI/control bridge, no remote model calls.
local core=require 'core'
core.add_thread(function()
local ok,err=xpcall(function()
  local shell=require 'shell';local registry=require('core.fleetagents').registry
  local launcher=require 'core.agentlauncher';local modal=require 'shell.modal'
  core.project_dir=system.absolute_path('.')
  local function frame(n)for _=1,n or 1 do core.redraw=true;registry:poll();coroutine.yield(0)end end
  local function await(check)
    local deadline=system.get_time()+10
    repeat frame();if check()then return end until system.get_time()>deadline
    error('Fleet keyboard deadline')
  end
  local function key(name,shift)
    local function event(kind,k,mods)system._test_event{type=kind,key=k,modifiers=mods or 0}end
    if shift then event('keypressed','Left Shift',1)end
    event('keypressed',name,shift and 1 or 0);event('keyreleased',name,shift and 1 or 0)
    if shift then event('keyreleased','Left Shift')end
    frame(2)
  end
  local fleet=require('core.swarmview').ensure()
  local function show(rec)
    shell.switch('fleet');fleet.selected=rec.id;fleet.action_focus:clear();frame(3)
  end
  local function focus(label)
    for _=1,#fleet.action_items+2 do
      key('Tab');local item=fleet.action_focus:current(fleet.action_items)
      if item and item.label==label then return item end
    end
    error('unreachable keyboard action: '..label)
  end
  local function activate(label,space)focus(label);key(space and 'Space' or 'Return')end
  local function text(view)
    view:sync(true);local rows={}
    for y=1,view.rows do local line={};for _,cell in ipairs(view.terminal:row(y).cells)do line[#line+1]=cell.text end;rows[#rows+1]=table.concat(line)end
    return table.concat(rows,'\n')
  end
  local rec,view=launcher.launch{provider='boggart',name='Keyboard native fixture',cmd=launcher.boggart_command(),
    args={'--eval',core.project_dir..'/tests/fixtures/agent_control_tui.lua'}}
  await(function()return rec.state=='idle' and rec.capabilities.prompt end);local pid,sid=rec.pid,rec.session_id
  show(rec)
  activate('New agent');assert(core.active_view==core.command_view,'keyboard opens actual launcher')
  key('Escape');assert(core.active_view==fleet and fleet.action_focus:current(fleet.action_items).label=='New agent','chooser returns focus')
  focus('Send prompt');local prompt_key=fleet.action_focus.key
  key('Tab',true);assert(fleet.action_focus:current(fleet.action_items).label=='Focus pane','Shift-Tab moves backward')
  local function prompt(input)
    activate('Send prompt');assert(core.active_view==core.command_view)
    system._test_event{type='textinput',text=input};frame(2)
    assert(core.active_view==core.command_view,'pasted newline does not activate submission')
    key('Return');assert(core.active_view==fleet)
  end
  prompt('hello\nfrom keyboard 🦊')
  await(function()return rec.state=='idle' and text(view):find('FIXTURE_ANSWER:hellofrom keyboard 🦊',1,true)end)
  assert(rec.pid==pid and rec.session_id==sid and fleet.action_focus.key==prompt_key,'same session and stable prompt focus')
  local extra=registry:register{provider='custom',name='Roster update'};registry:retire(extra.id,1,'exited');frame(3)
  assert(fleet.selected==rec.id and fleet.action_focus.key==prompt_key,'roster append preserves focus/selection')
  prompt('wait');await(function()return rec.state=='running'end)
  activate('Interrupt',true);await(function()return rec.state=='idle'end)
  assert(not modal.pending,'focused Space activates before leader shortcuts')
  prompt('approval');await(function()return rec.state=='waiting_for_approval' and rec.request end)
  local old_request=rec.request.id;local stale=focus('Approve')
  activate('Reject');await(function()return rec.state=='idle'end)
  assert(not fleet.action_focus.key,'disappearing approval does not transfer focus')
  prompt('approval');await(function()return rec.state=='waiting_for_approval' and rec.request.id~=old_request end)
  stale.action();assert(rec.state=='waiting_for_approval' and fleet.notice.bad,'stale callback cannot approve replacement')
  -- A narrow real window must keep every supported detail action reachable.
  system.set_window_size(520,700);frame(5)
  for _,label in ipairs{'Focus pane','Interrupt','Approve','Reject','Stop'}do focus(label)end
  for _,hit in ipairs(fleet.hits)do if hit.item.key and not hit.item.key:find('toolbar:',1,true)then
    assert(hit.y+hit.h<=fleet.detail_bottom,'partially clipped detail controls are not interactive')
    assert(hit.x+hit.w<=fleet.position.x+fleet.size.x,'horizontally clipped controls are not interactive')
  end end
  focus('Approve');frame(3)
  if os.getenv('BMUX_RENDER_DIR')then assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/fleet-keyboard-focus.bmp'))end
  activate('Approve',true);await(function()return rec.state=='idle' and text(view):find('FIXTURE_APPROVED',1,true)end)
  prompt('workers');await(function()return rec.state=='running'end)
  local child
  await(function()for _,row in ipairs(registry:records())do if row.parent==rec.id and row.state=='running' and row.worker then child=row;return true end end end)
  show(child);activate('Cancel worker');await(function()return child.state=='stopped'end)
  show(rec);activate('Interrupt');await(function()return rec.state=='idle'end)
  activate('Focus pane');assert(core.active_view==view and shell.current=='bmux')
  view:send('/quit\r');await(function()return rec.state=='exited'end)

  local foreign,fview=launcher.launch{provider='custom',name='Foreign attention',cmd='/bin/sh',args={'-c','IFS= read -r line'}}
  await(function()return foreign.state=='alive'end)
  registry:update(foreign.id,1,{attention=true,reported_at=1,reported_event='Notification'})
  show(foreign)
  for _,item in ipairs(fleet.action_items)do assert(item.label~='Approve' and item.label~='Send prompt')end
  activate('Focus pane');assert(core.active_view==fview and not foreign.attention)
  show(foreign);activate('Stop');assert(foreign.state=='stopped' and fview.terminal==nil)

  -- Legacy in-process actors use the same action list, with incarnation checks.
  local dash=require 'dash';local internal=dash.touch(900123);internal.kind='Keyboard actor'
  local actor=bog.sched.add(internal.id,coroutine.create(function()while true do coroutine.yield('approve')end end))
  show(internal);activate('Pause');assert(actor.paused)
  activate('Resume');assert(not actor.paused)
  focus('Kill');key('Escape');assert(not fleet.action_focus.key and bog.sched.by_id[internal.id]==actor,'Escape returns to roster without killing')
  key('Space');assert(modal.pending=='leader','roster retains Space leader shortcut');key('Escape')
  activate('Kill');assert(not bog.sched.by_id[internal.id])
  local calls=0;local replacement=registry:register{provider='fixture',name='Runtime identity'}
  registry:bind(replacement.id,1,{stop=function()calls=calls+1;return true end})
  registry:update(replacement.id,1,{state='alive'});show(replacement)
  local old_runtime=focus('Stop');replacement.generation=2
  old_runtime.action();assert(calls==0 and fleet.notice.bad,'old runtime callback cannot reach a replacement')
  frame(3);assert(not fleet.action_focus.key,'replacement runtime does not inherit focus')
  registry:retire(replacement.id,2,'stopped')
  print('studio_fleet_keyboard: SDL Tab/Shift-Tab/Space/Enter, launcher/prompt return, paste, stable/stale identities, narrow actions, real TUI approvals/workers, foreign focus and actor controls pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
core.quit(true)
end)
