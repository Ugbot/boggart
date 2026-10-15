local application=require 'core'
application.add_thread(function()
local ok,err=xpcall(function()
  local core=require 'core';local shell=require 'shell';local ws=require 'shell.workspaces.bmux'
  local registry=require('fleet').default;local uv=require 'uv';local command=require 'core.command'
  local function quote(s)return "'"..s:gsub("'","'\\''").."'"end
  local function frame()
    core.redraw=true;registry:poll();coroutine.yield(0)
  end
  local function await(check)
    local deadline=system.get_time()+7
    repeat frame();if check()then return end until system.get_time()>deadline
    error('manual agent deadline')
  end
  local function line(view,wanted)
    view:sync(true)
    for y=1,view.history_rows+view.rows do
      local text={};for _,cell in ipairs(view:visible_row(y).cells)do text[#text+1]=cell.text end
      if table.concat(text):gsub('%s+$','')==wanted then return true end
    end
  end
  local function named(name)
    for _,rec in ipairs(registry:records())do if rec.manual and rec.name==name then return rec end end
  end
  local exe=require('core.agentlauncher').boggart_command()
  local dir=assert(uv.fs_mkdtemp('/tmp/bmux-manual-fixture-XXXXXX'))
  shell.switch('bmux');local first=core.active_view
  assert(first.terminal and not first.spawn_error,tostring(first.spawn_error))
  local manual=require 'core.manualagents';local socket=manual.socket
  assert(uv.fs_stat(socket).mode%512==384)
  -- The CLI must work with an unusable data home: no Lua, store or models.
  first:send('BOGGART_HOME=/dev/null '..quote(exe)..' ctl health\n')
  await(function()return line(first,'{"ok":true,"transport":"unix"}')end)
  local label='Typed foreign agent'
  local script='printf "<%s>\\n" "$1"; IFS= read -r input; printf "INPUT:%s\\n" "$input"; exit 7'
  first:send(quote(exe)..' ctl run --provider foreign --name '..quote(label)..' -- /bin/sh -c '..quote(script)..' -- '..quote('$HOME $(literal) 🦊')..'\n')
  local rec
  await(function()rec=named(label);return rec and rec.state=='alive'end)
  assert(rec.pid>0 and rec.pane_id==first.manual_pane and rec.capabilities.focus and not rec.capabilities.stop)
  await(function()return line(first,'<$HOME $(literal) 🦊>')end)
  local second=ws.open('right');assert(second and second~=first and second.manual_pane~=first.manual_pane)
  local fleet=require('core.swarmview').ensure();shell.switch('fleet');fleet.selected=rec.id
  for _=1,3 do frame()end
  local focus
  for _,hit in ipairs(fleet.hits)do
    assert(hit.item.label~='Stop agent','manual process IDs confer no kill authority')
    if hit.item.label=='Focus pane' then focus=hit end
  end
  assert(focus,'Fleet exposes manual agent focus')
  if os.getenv('BMUX_RENDER_DIR')then assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/fleet-manual.bmp'))end
  core.on_event('mousepressed','left',focus.x+focus.w/2,focus.y+focus.h/2,1)
  core.on_event('mousereleased','left',focus.x+focus.w/2,focus.y+focus.h/2,1);frame()
  assert(core.active_view==first and shell.current=='bmux')
  first:send('literal input\n')
  await(function()return rec.state=='failed' and rec.exit_status==7 end)
  await(function()return line(first,'INPUT:literal input')end)
  local function listing(view,name,arguments)
    local path=dir..'/'..name
    view:send(quote(exe)..' ctl agents '..(arguments or '')..' > '..quote(path)..'\n')
    local page
    await(function()
      local f=io.open(path);if not f then return end
      local text=f:read('*a');f:close();local parsed,value=pcall(require('json').decode,text)
      if parsed then page=value;return true end
    end)
    uv.fs_unlink(path);return page
  end
  local page=listing(first,'owner-list','--offset 0 --limit 1')
  assert(page.total==1 and page.agents[1].id==rec.id,'native client paginates owning-pane roster')
  local other_page=listing(second,'other-list')
  assert(other_page.total==0 and #other_page.agents==0,'another shell has its own scoped roster')
  first:send(quote(exe)..' ctl run --name Missing -- /bmux/does-not-exist\n')
  await(function()local missing=named('Missing');return missing and missing.state=='failed' and missing.exit_status==127 end)

  first:send(quote(exe)..' ctl run --name Interrupt -- /bin/sleep 30\n')
  local interrupted
  await(function()interrupted=named('Interrupt');return interrupted and interrupted.state=='alive'end)
  first:send('\3')
  await(function()return interrupted.state=='failed' and interrupted.term_signal==2 end)
  first:send("printf 'SHELL_AFTER_INTERRUPT\\n'\n")
  await(function()return line(first,'SHELL_AFTER_INTERRUPT')end)

  local pidfile=dir..'/wrapper'
  first:send(quote(exe)..' ctl run --name Lost -- /bin/sh -c '..quote('printf "%s" "$PPID" > '..quote(pidfile)..'; exec /bin/sleep 30')..'\n')
  local lost
  await(function()lost=named('Lost');return lost and lost.state=='alive' and uv.fs_stat(pidfile)end)
  local f=assert(io.open(pidfile));local wrapper_pid=assert(tonumber(f:read('*a')));f:close()
  assert(wrapper_pid~=lost.pid);assert(uv.kill(wrapper_pid,'sigkill'))
  manual.service.ttl=.1
  await(function()return lost.state=='unreachable'end)
  assert(lost.capabilities.focus and not lost.capabilities.stop and not lost.exit_status,'wrapper loss keeps process outcome unknown')
  assert(uv.kill(lost.pid,'sigterm'));uv.fs_unlink(pidfile);uv.fs_rmdir(dir)
  core.set_active_view(first);command.perform('bmux:close-terminal');frame()
  assert(rec.retired and rec.state=='failed' and not rec.capabilities.focus)
  assert(lost.retired and lost.state=='unreachable' and not lost.capabilities.focus)
  local pane=second.manual_pane;assert(manual.service.panes[pane])
  manual.shutdown();assert(not uv.fs_stat(socket) and not manual.service.panes[pane])
  print('studio_manual_agents: typed wrapper, native startup, literal argv/stdin, Fleet focus, exit, spawn failure, interrupt, wrapper loss and pane retirement pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
end)
