local ok,err=xpcall(function()
  local core=require 'core';local launcher=require 'core.agentlauncher';local shell=require 'shell'
  local registry=require('core.fleetagents').registry
  core.project_dir=system.absolute_path('.')
  local function frame(n)
    for _=1,n or 1 do core.redraw=true;core.frame_start=system.get_time();core.step();registry:poll()end
  end
  local function await(check)
    local until_at=system.get_time()+8
    repeat frame();if check()then return end;system.wait_event(.01)until system.get_time()>until_at
    error('agent control deadline')
  end
  local function screen(view)
    view:sync(true);local out={}
    for y=1,view.rows do local line={};for _,c in ipairs(view.terminal:row(y).cells)do line[#line+1]=c.text end;out[#out+1]=table.concat(line)end
    return table.concat(out,'\n')
  end
  local rec,view=launcher.launch{provider='boggart',name='Control fixture',cmd=launcher.boggart_command(),
    args={'--eval',core.project_dir..'/tests/fixtures/agent_control_tui.lua'}}
  await(function()return rec.state=='idle' and rec.session_id and rec.capabilities.prompt end)
  assert(rec.model and rec.input_revision==0 and view.terminal:channel(),'real session reports over inherited channel')
  local sid,pid=rec.session_id,rec.pid
  assert(not registry:control(rec.id,rec.generation+1,'prompt',{text='stale'}))
  local function command(action,payload,accepted)
    local sent,id=registry:control(rec.id,rec.generation,action,payload);assert(sent,id)
    await(function()return rec.control_result and rec.control_result.id==id end)
    assert(rec.control_result.accepted==accepted,rec.control_result.error);return id
  end
  shell.switch('fleet');local fleet=require('core.swarmview').ensure();fleet.selected=rec.id;frame(3)
  local function click(label)
    frame(3);local hit;for _,r in ipairs(fleet.hits)do if r.item.label==label then hit=r;break end end
    assert(hit,'Fleet control '..label)
    core.on_event('mousepressed','left',hit.x+hit.w/2,hit.y+hit.h/2,1)
    core.on_event('mousereleased','left',hit.x+hit.w/2,hit.y+hit.h/2,1);frame()
  end
  click('Send prompt');core.command_view:set_text('from Fleet button');core.command_view:submit()
  await(function()return rec.state=='idle' and screen(view):find('FIXTURE_ANSWER:from Fleet button',1,true)end)
  -- Native terminal keys and structured commands contend on the same draft.
  view:send('human draft');await(function()return rec.draft_bytes==11 end)
  command('prompt',{text='must not overwrite'},false)
  assert(screen(view):find('human draft',1,true))
  local stale_revision=rec.input_revision
  view:send('\21');await(function()return rec.draft_bytes==0 end) -- Ctrl-U
  command('prompt',{text='stale draft revision',input_revision=stale_revision},false)
  command('prompt',{text='hello'},true)
  await(function()return rec.state=='idle' and screen(view):find('FIXTURE_ANSWER:hello',1,true)end)
  assert(rec.session_id==sid and rec.pid==pid,'prompt uses original session/process')

  command('prompt',{text='wait'},true);await(function()return rec.state=='running'end)
  command('prompt',{text='finish'},true)
  await(function()return rec.state=='idle' and screen(view):find('FIXTURE_STEER:finish',1,true)end)
  command('prompt',{text='wait'},true);await(function()return rec.state=='running'end)
  click('Interrupt');await(function()return rec.state=='idle'end)
  assert(rec.pid==pid and rec.capabilities.prompt,'interrupt cancels turn without killing TUI')

  command('prompt',{text='approval'},true)
  await(function()return rec.state=='waiting_for_approval' and rec.request and rec.capabilities.approve end)
  local first=rec.request.id
  command('approve',{request_id='old request',decision='approve'},false)
  assert(rec.request.id==first and rec.state=='waiting_for_approval')
  -- Click real Fleet approval widgets, which capture the current request ID.
  shell.switch('fleet');fleet.selected=rec.id;frame(3)
  click('Reject');await(function()return rec.state=='idle' and screen(view):find('FIXTURE_REJECTED',1,true)end)
  command('prompt',{text='approval'},true)
  await(function()return rec.state=='waiting_for_approval' and rec.request end)
  assert(rec.request.id~=first)
  command('approve',{request_id=first,decision='approve'},false)
  frame(3)
  if os.getenv('BMUX_RENDER_DIR')then assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/fleet-approval.bmp'))end
  frame(3);click('Approve');await(function()return rec.state=='idle' and screen(view):find('FIXTURE_APPROVED',1,true)end)
  assert(rec.session_id==sid and rec.pid==pid)
  assert(registry:control(rec.id,rec.generation,'focus'));view:send('/quit\r')
  await(function()return rec.state=='exited'end)
  assert(not rec.capabilities.prompt and not rec.capabilities.approve and rec.session_id==sid)
  local channel=view.terminal:channel();getmetatable(channel).__gc(channel)
  assert(channel:receive()==nil and channel:state().closed);channel:close()
  local lost,lost_view=launcher.launch{provider='boggart',name='Channel loss fixture',cmd=launcher.boggart_command(),
    args={'--eval',core.project_dir..'/tests/fixtures/agent_control_tui.lua'}}
  await(function()return lost.state=='idle' and lost.capabilities.prompt end)
  lost_view.terminal:channel():close()
  await(function()return lost.state=='alive' and not lost.capabilities.prompt and lost.error end)
  assert(lost.capabilities.focus and lost.capabilities.stop,'channel loss preserves process controls')
  lost_view:send('/quit\r');await(function()return lost.state=='exited'end)
  print('Agent control: real TUI handshake/session, human draft/stale revision guards, prompt/steer/interrupt, exact live approvals and Fleet clicks pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
