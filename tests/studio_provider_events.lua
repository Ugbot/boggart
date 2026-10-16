-- Real Studio loop, generated provider plugin, native ctl and both launch paths.
local core=require 'core'
require('core.config').bmux_server=false -- provider hook fixture uses local PTY ownership
core.add_thread(function()
local ok,err=xpcall(function()
  local uv=require 'uv';local shell=require 'shell';local registry=require('fleet').default
  local ws=require 'shell.workspaces.bmux';local launcher=require 'core.agentlauncher'
  core.project_dir=system.absolute_path('.')
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local function frame()core.redraw=true;registry:poll();coroutine.yield(0)end
  local function await(check)
    local deadline=system.get_time()+10
    repeat frame();if check()then return end until system.get_time()>deadline
    error('provider event deadline')
  end
  local function screen(view)
    view:sync(true);local rows={}
    for y=1,view.history_rows+view.rows do local cells={}
      for _,cell in ipairs(view:visible_row(y).cells)do cells[#cells+1]=cell.text end
      rows[#rows+1]=table.concat(cells)
    end
    return table.concat(rows,'\n')
  end
  local original_path=os.getenv('PATH');local fixture=assert(uv.fs_mkdtemp('/tmp/bmux-hooks-studio-XXXXXX'))
  local f=assert(io.open(fixture..'/claude','w'))
  f:write('#!/bin/sh\ncase "$1" in --plugin-dir=*) BMUX_HOOK_FIXTURE_PLUGIN=${1#--plugin-dir=}; export BMUX_HOOK_FIXTURE_PLUGIN; shift;; *) exit 92;; esac\n',
    'exec ',q(launcher.boggart_command()),' --eval ',q(core.project_dir..'/tests/fixtures/provider_hooks_driver.lua'),'\n')
  f:close();assert(uv.fs_chmod(fixture..'/claude',448));assert(uv.os_setenv('PATH',fixture..':'..original_path))
  shell.switch('bmux');local first=core.active_view;local manual=require 'core.manualagents'
  local plugin=assert(manual.hooks.claude_plugin);local before=#registry.order
  first:send('claude\n');local ordinary
  await(function()
    ordinary=registry.agents[registry.order[#registry.order]]
    return #registry.order==before+1 and ordinary.state=='idle' and screen(first):find('HOOK_READY',1,true)
  end)
  assert(ordinary.manual and ordinary.pane_id==first.manual_pane)
  local function exercise(rec,view)
    local function send(text,state)
      view:send(text..'\n');await(function()return rec.state==state end)
    end
    send('run','running');send('approval','waiting_for_approval')
    assert(rec.attention and rec.reported_event=='PermissionRequest')
    assert(not rec.capabilities.approve and not rec.capabilities.prompt and not rec.request,'reports grant no decision controls')
    shell.switch('fleet');local fleet=require('core.swarmview').ensure();fleet.selected=rec.id
    for _=1,4 do frame()end
    for _,hit in ipairs(fleet.hits)do assert(hit.item.label~='Approve' and hit.item.label~='Reject' and hit.item.label~='Send prompt')end
    if os.getenv('BMUX_RENDER_DIR')then assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/fleet-provider-attention.bmp'))end
    assert(registry:control(rec.id,rec.generation,'focus') and core.active_view==view and not rec.attention)
    local acknowledged=rec.reported_at
    local until_at=system.get_time()+1.2
    repeat frame()until system.get_time()>until_at
    assert(rec.state=='waiting_for_approval' and not rec.attention and rec.reported_at==acknowledged,'poll/heartbeat preserves acknowledged phase')
    view:send('child\n');await(function()return screen(view):find('HOOK_SENT:child',1,true)end)
    assert(rec.state=='waiting_for_approval' and not rec.attention,'subagent stop does not clobber root')
    send('tool','running');assert(not rec.attention)
    send('answer','waiting_for_answer');assert(rec.attention)
    send('stop','idle');assert(rec.attention)
  end
  exercise(ordinary,first);first:send('quit\n');await(function()return ordinary.state=='exited'end)
  assert(ordinary.exit_status==0 and not ordinary.attention)
  before=#registry.order
  local managed,view=launcher.launch{provider='claude',name='Managed hook fixture',cmd='claude'}
  await(function()return managed.state=='idle' and screen(view):find('HOOK_READY',1,true)end)
  assert(#registry.order==before+1 and not managed.manual and view.provider_events,'one managed process owner')
  exercise(managed,view);view:send('crash\n');await(function()return managed.state=='failed'end)
  assert(managed.exit_status==7 and not managed.attention,'native exit overrides last reported phase')
  view:try_close(function()end);manual.shutdown()
  assert(not uv.fs_stat(plugin),'generated plugin removed at shutdown')
  assert(uv.os_setenv('PATH',original_path));assert(uv.fs_unlink(fixture..'/claude'));assert(uv.fs_rmdir(fixture))
  print('studio_provider_events: generated plugin, ordinary/managed ownership, phases, attention, focus, subagent isolation and native exit pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
core.quit(true)
end)
