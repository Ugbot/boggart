local ok,err=xpcall(function()
  local core=require 'core';local shell=require 'shell';local launcher=require 'core.agentlauncher'
  local registry=require('core.fleetagents').registry;local dash=require 'dash'
  core.project_dir=system.absolute_path('.')
  local function frame(n)
    for _=1,n or 1 do core.redraw=true;core.frame_start=system.get_time();core.step();registry:poll()end
  end
  local function await(check)
    local until_at=system.get_time()+8
    repeat frame();if check()then return end;system.wait_event(.01)until system.get_time()>until_at
    error('worker Fleet deadline')
  end
  local rec,view=launcher.launch{provider='boggart',name='Worker Fleet fixture',cmd=launcher.boggart_command(),
    args={'--eval',core.project_dir..'/tests/fixtures/agent_control_tui.lua'}}
  await(function()return rec.state=='idle' and rec.capabilities.prompt end)
  local pid,sid=rec.pid,rec.session_id
  local internal=dash.touch(900099);internal.kind='internal fixture'
  local foreign,foreign_view=launcher.launch{provider='custom',name='Foreign fixture',cmd='/bin/sh',args={'-c','IFS= read -r line'}}
  local function children()
    local out={};for _,child in ipairs(registry:records())do if child.parent==rec.id and child.worker then out[#out+1]=child end end
    return out
  end
  assert(registry:control(rec.id,1,'prompt',{text='workers'}))
  await(function()
    local live,done,failed=0,0,0
    for _,child in ipairs(children())do
      if child.state=='running' then live=live+1 elseif child.state=='exited' then done=done+1 elseif child.state=='failed' then failed=failed+1 end
    end
    return live==2 and done==2 and failed==1
  end)
  local rows=children();assert(#rows==5 and rec.state=='running')
  local all=registry:records();local parent_at
  for i,r in ipairs(all)do if r==rec then parent_at=i end end
  for i=1,5 do assert(all[parent_at+i].parent==rec.id,'worker rows group beneath their owning TUI')end
  local nested,live={},{}
  for _,child in ipairs(rows)do
    assert(child.model and child.session_id~=sid and child.capabilities.focus)
    if child.state=='running' then live[#live+1]=child end
    if child.parent_session_id~=sid then nested[#nested+1]=child end
  end
  assert(#nested==1 and (nested[1].parent_session_id==live[1].session_id or nested[1].parent_session_id==live[2].session_id))
  local found_internal,found_foreign=false,false
  for _,r in ipairs(registry:records())do found_internal=found_internal or r==internal;found_foreign=found_foreign or r==foreign end
  assert(found_internal and found_foreign,'internal, foreign, TUI and workers share the one roster')
  assert(registry:control(live[1].id,1,'focus') and core.active_view==view and shell.current=='bmux')
  assert(rec.pid==pid and rec.session_id==sid,'worker focus uses owning TUI, no second engine')
  local fleet=require('core.swarmview').ensure();shell.switch('fleet');fleet.selected=live[1].id;frame(3)
  local function click(label)
    frame(3);local hit;for _,h in ipairs(fleet.hits)do if h.item.label==label then hit=h;break end end
    assert(hit,'worker control '..label)
    core.on_event('mousepressed','left',hit.x+hit.w/2,hit.y+hit.h/2,1)
    core.on_event('mousereleased','left',hit.x+hit.w/2,hit.y+hit.h/2,1);frame()
  end
  if os.getenv('BMUX_RENDER_DIR')then assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/fleet-workers.bmp'))end
  click('Cancel worker');await(function()return live[1].state=='stopped' and live[1].control_result end)
  assert(live[1].control_result.accepted and live[2].state=='running' and rec.state=='running')
  assert(not registry:control(live[1].id,1,'stop') and not registry:control(live[2].id,2,'stop'))
  assert(registry:control(live[2].id,1,'stop'));await(function()return rec.state=='idle' and live[2].state=='stopped'end)
  assert(rec.pid==pid and rec.session_id==sid and rec.capabilities.prompt)

  assert(registry:control(rec.id,1,'prompt',{text='workers asking'}))
  local asking
  await(function()
    for _,child in ipairs(children())do if child.state=='waiting_for_approval' then asking=child;return true end end
  end)
  assert(rec.state=='waiting_for_approval' and rec.capabilities.approve and asking.capabilities.stop)
  assert(registry:control(asking.id,1,'stop'))
  await(function()return rec.state=='idle' and asking.state=='stopped'end)
  assert(not rec.capabilities.approve,'cancelled worker cannot strand its approval bar')

  -- A second wave survives the slot accounting from completed/cancelled workers.
  assert(registry:control(rec.id,1,'prompt',{text='workers'}))
  local active
  await(function()
    active={};for _,child in ipairs(children())do if child.state=='running' then active[#active+1]=child end end
    return #active==2
  end)
  assert(#children()==11)
  view.terminal:channel():close()
  await(function()return active[1].state=='unreachable' and active[2].state=='unreachable'end)
  assert(not active[1].capabilities.stop and active[1].capabilities.focus and rec.state=='alive')
  assert(registry:control(rec.id,1,'stop'))
  for _,child in ipairs(children())do
    assert(child.state~='running' and child.state~='unreachable' and not child.capabilities.focus)
  end
  assert(foreign.state=='alive','worker/owner control does not cancel unrelated agents')
  local killed,killed_view=launcher.launch{provider='boggart',name='Worker exit fixture',cmd=launcher.boggart_command(),
    args={'--eval',core.project_dir..'/tests/fixtures/agent_control_tui.lua'}}
  await(function()return killed.state=='idle' and killed.capabilities.prompt end)
  assert(registry:control(killed.id,1,'prompt',{text='workers'}))
  local killed_children
  await(function()
    killed_children={}
    for _,child in ipairs(registry:records())do if child.parent==killed.id and child.state=='running' then killed_children[#killed_children+1]=child end end
    return #killed_children==2
  end)
  assert(require('uv').kill(killed.pid,'sigkill')) -- Only this fixture's live owned child.
  await(function()return killed.state=='failed'end)
  for _,child in ipairs(killed_children)do
    assert(child.state=='stopped' and not child.capabilities.stop and child.capabilities.focus)
  end
  killed_view:try_close(function()end)
  for _,child in ipairs(killed_children)do assert(not child.capabilities.focus)end
  assert(foreign.state=='alive','parent process failure does not affect unrelated agents')
  foreign_view:try_close(function()end)
  print('Fleet workers: real TUI transient/live/failure/nested workers, shared foreign/internal roster, focus/cancel clicks, repeat waves, channel loss and parent close pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
