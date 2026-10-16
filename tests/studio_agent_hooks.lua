-- Ordinary shell commands, real native wrappers and the real application loop.
local application=require 'core'
require('core.config').bmux_server=false -- exercise local wrappers, not the managed server
application.add_thread(function()
local ok,err=xpcall(function()
  local uv=require 'uv';local core=require 'core';local shell=require 'shell'
  local registry=require('fleet').default;local ws=require 'shell.workspaces.bmux'
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local function frame()core.redraw=true;registry:poll();coroutine.yield(0)end
  local function await(check)
    local deadline=system.get_time()+8
    repeat frame();if check()then return end until system.get_time()>deadline
    error('automatic agent deadline')
  end
  local function shell_ready(view)
    await(function()return view.terminal:foreground_group()==view.terminal:process_state().pid and not view.state.alternate end)
  end
  local function line(view,wanted)
    view:sync(true)
    for y=1,view.history_rows+view.rows do
      local text={};for _,cell in ipairs(view:visible_row(y).cells)do text[#text+1]=cell.text end
      if table.concat(text):gsub('%s+$','')==wanted then return true end
    end
  end
  local function latest(provider)
    for i=#registry.order,1,-1 do local rec=registry.agents[registry.order[i]]
      if rec.manual and rec.provider==provider then return rec end
    end
  end
  local original_path=os.getenv('PATH');local fixture=assert(uv.fs_mkdtemp('/tmp/bmux-provider-fixture-XXXXXX'))
  for _,provider in ipairs{'codex','claude','opencode','gemini'}do
    local f=assert(io.open(fixture..'/'..provider,'w'))
    f:write('#!/bin/sh\ncase "${1-}" in --plugin-dir=*) shift;; esac\ncase "${1-}" in --help) printf "HELP\\n"; exit 0;; esac\n',
      'if [ "${1-}" = nested ]; then claude child; exit $?; fi\n',
      'printf "%s:<%s>\\n" '..q(provider)..' "$1"\nIFS= read -r input\nprintf "INPUT:%s\\n" "$input"\n',
      'if [ "${1-}" = exit125 ]; then exit 125; fi\nexit 7\n')
    f:close();assert(uv.fs_chmod(fixture..'/'..provider,448))
  end
  assert(uv.os_setenv('PATH',fixture..':'..original_path))
  shell.switch('bmux');local first=core.active_view;local manual=require 'core.manualagents'
  assert(first.terminal and manual.hooks,'BMUX installs automatic wrappers')
  local bin=manual.hooks.bin
  for _,provider in ipairs{'codex','claude','opencode','gemini'}do
    local before=#registry.order
    first:send(provider..' --help\n')
    first:send("printf 'HELP_FINISHED_"..provider.."\\n'\n")
    await(function()return line(first,'HELP_FINISHED_'..provider)end)
    assert(#registry.order==before,'help is not an agent runtime')
    first:send(provider..' '..q('$HOME $(literal) 🦊')..'\n')
    local rec
    await(function()rec=latest(provider);return rec and rec.state=='alive'end)
    assert(#registry.order==before+1 and rec.pane_id==first.manual_pane and not rec.capabilities.stop)
    await(function()return line(first,provider..':<$HOME $(literal) 🦊>')end)
    first:send('response\n');await(function()return rec.state=='failed' and rec.exit_status==7 end)
    shell_ready(first)
  end
  local count=#registry.order
  first:send('boggart --version\nprintf \'VERSION_FINISHED\\n\'\n')
  await(function()return line(first,'VERSION_FINISHED')end);assert(#registry.order==count)

  -- Absolute sibling Boggart is wrapped once; no remote model request is made.
  first:send('boggart --tui\n');local native
  await(function()native=latest('boggart');return native and native.state=='alive' and first.state.alternate end)
  first:send('/quit\r');await(function()return native.state=='exited' and native.exit_status==0 end)
  shell_ready(first)
  assert(#registry.order==count+1)

  -- Explicit wrapping bypasses both the canonical injected bin and its alias.
  local alias=fixture..'/bin-alias';assert(uv.fs_symlink(bin,alias))
  count=#registry.order
  first:send('PATH='..q(alias..':'..manual.hooks.path)..' boggart ctl run --provider custom --name Explicit -- codex explicit\n')
  local explicit
  local ready,why=pcall(await,function()explicit=latest('custom');return explicit and explicit.state=='alive'end)
  if not ready then
    local rows={};first:sync(true)
    for y=1,first.history_rows+first.rows do
      local text={};for _,cell in ipairs(first:visible_row(y).cells)do text[#text+1]=cell.text end
      rows[#rows+1]=table.concat(text)
    end
    error(tostring(why)..'\n'..require('json').encode(explicit or {})..'\n'..table.concat(rows,'\n'))
  end
  assert(#registry.order==count+1,'explicit wrapping must create one registration')
  first:send('done\n');await(function()return explicit.state=='failed'end)
  shell_ready(first)
  count=#registry.order
  first:send('boggart ctl run --provider custom --name Absolute -- '..q(bin..'/codex')..' absolute\n')
  local absolute
  await(function()absolute=latest('custom');return absolute and absolute~=explicit and absolute.state=='alive'end)
  assert(#registry.order==count+1,'an absolute wrapper path also resolves to one execution owner')
  first:send('done\n');await(function()return absolute.state=='failed'end);shell_ready(first)
  count=#registry.order
  first:send('boggart ctl run --provider boggart --name ExplicitBoggart -- boggart --tui\n')
  local explicit_native
  await(function()explicit_native=latest('boggart');return explicit_native and explicit_native~=native and explicit_native.state=='alive' and first.state.alternate end)
  first:send('/quit\r');await(function()return explicit_native.state=='exited'end);shell_ready(first)
  assert(#registry.order==count+1)
  uv.fs_unlink(alias)

  -- Children keep the wrapper PATH, so nested agents also belong in Fleet.
  count=#registry.order;first:send('codex nested\n');local parent,child
  await(function()parent=latest('codex');child=latest('claude');return #registry.order==count+2 and parent.state=='alive' and child.state=='alive'end)
  local second=ws.open('right');assert(second and second~=first)
  shell.switch('fleet');local fleet=require('core.swarmview').ensure();fleet.selected=child.id
  for _=1,3 do frame()end
  if os.getenv('BMUX_RENDER_DIR')then assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/fleet-auto.bmp'))end
  assert(registry:control(child.id,1,'focus') and core.active_view==first and shell.current=='bmux')
  first:send('nested response\n');await(function()return child.state=='failed' and parent.state=='failed'end)
  shell_ready(first)

  -- A Studio inherited from BMUX can already have wrappers in its parent PATH.
  -- New agent still owns one direct execution, rather than launching a wrapper.
  assert(uv.os_setenv('PATH',manual.hooks.path));count=#registry.order
  local managed,managed_view=require('core.agentlauncher').launch{provider='codex',name='Managed fixture',cmd='codex',args={'managed'}}
  await(function()return managed and managed.state=='alive' and line(managed_view,'codex:<managed>')end)
  assert(#registry.order==count+1 and not managed.manual,'launcher does not duplicate an automatic registration')
  managed_view:send('done\n');await(function()return managed.state=='failed'end)
  managed_view:try_close(function()end);assert(uv.os_setenv('PATH',fixture..':'..original_path));ws.show(first)

  count=#registry.order;first:send('BOGGART_AGENT_HOOKS=0 codex opted-out\n')
  await(function()return line(first,'codex:<opted-out>')end);assert(#registry.order==count)
  first:send('done\n');first:send("printf 'OPT_OUT_FINISHED\\n'\n")
  await(function()return line(first,'OPT_OUT_FINISHED')end)
  shell_ready(first)
  count=#registry.order;first:send('BOGGART_PANE_TOKEN=invalid codex fallback\n')
  await(function()return line(first,'codex:<fallback>')end);assert(#registry.order==count,'rejected registration still launches the ordinary agent')
  first:send('done\n');first:send("printf 'FALLBACK_FINISHED\\n'\n")
  await(function()return line(first,'FALLBACK_FINISHED')end);shell_ready(first)
  first:send('codex exit125\n');local code125
  await(function()code125=latest('codex');return code125 and code125.state=='alive'end)
  first:send('done\n');await(function()return code125.state=='failed' and code125.exit_status==125 end)
  shell_ready(first);assert(#registry.order==count+1,'a real exit 125 is never retried as a registration failure')
  local directory=manual.directory;manual.shutdown()
  assert(not uv.fs_stat(bin) and not uv.fs_stat(directory),'private wrapper artifacts removed on shutdown')
  local opt_out=os.getenv('BOGGART_AGENT_HOOKS');assert(uv.os_setenv('BOGGART_AGENT_HOOKS','0'))
  manual.start();assert(not manual.hooks,'whole-Studio opt-out avoids installing wrappers');manual.shutdown()
  if opt_out then uv.os_setenv('BOGGART_AGENT_HOOKS',opt_out)else uv.os_unsetenv('BOGGART_AGENT_HOOKS')end
  for _,provider in ipairs{'codex','claude','opencode','gemini'}do assert(uv.fs_unlink(fixture..'/'..provider))end
  assert(uv.fs_rmdir(fixture));assert(uv.os_setenv('PATH',original_path))
  print('studio_agent_hooks: ordinary CLI registration, utility bypass, real Boggart TUI, literal argv, explicit dedup, nested agents, Fleet focus, opt-out and cleanup pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
application.quit(true)
end)
