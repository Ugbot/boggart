-- Actual Studio dispatch and native PTY pane integration, using SDL's queue.
local ok,err=xpcall(function()
  local core=require 'core'; local terminal=require 'terminal'; local View=require 'core.terminalview'
  local keymap=require 'core.keymap'; local style=require 'core.style'
  assert(package.loaded['plugins.panes'] and package.loaded['plugins.terminal'],'pane plugins load from disk or embedded assets')
  local asset_plugins=assert(system.list_dir('@assets/plugins')); local seen={}
  for _,name in ipairs(asset_plugins) do assert(not seen[name]); seen[name]=true end
  assert(seen['panes.lua'] and seen['terminal.lua'],'embedded directory lists actual plugins')
  assert(View.feed==nil and View.step_byte==nil and rawget(_G,'pty')==nil,'no legacy parser/PTY on the pane path')
  local t <close> =terminal.new(80,24,20); local captured={}
  local view=View{terminal=t,send=function(s) captured[#captured+1]=s; return true end}
  local node=core.root_view:get_active_node(); node:add_view(view)
  local function frame() core.frame_start=system.get_time(); core.step() end
  frame(); frame()
  local function take(expected) local actual=table.concat(captured); captured={}; assert(actual==expected,string.format('expected %q got %q',expected,actual)) end
  local function push(type,key,mods,text,repeat_key)
    system._test_event{type=type,key=key,modifiers=mods or 0,text=text,['repeat']=repeat_key and 1 or 0}
  end
  push('keypressed','A'); push('textinput',nil,0,'a'); push('keyreleased','A'); frame(); take('a')
  push('keypressed','Left Ctrl',terminal.CTRL); push('keypressed','C',terminal.CTRL)
  push('keyreleased','C',terminal.CTRL); push('keyreleased','Left Ctrl'); frame(); take('\3')
  t:feed('\27[?1h'); push('keypressed','Up'); push('keyreleased','Up'); frame(); take('\27OA')
  push('keypressed','E'); push('textediting',nil,0,'´'); frame(); take('')
  push('keypressed','E'); push('textinput',nil,0,'é'); push('keyreleased','E'); frame(); take('é')
  t:feed('\27[>31u'); view:sync(true)
  push('keypressed','Left Shift',terminal.SHIFT); push('keypressed','A',terminal.SHIFT)
  push('textinput',nil,0,'A'); push('keyreleased','A',terminal.SHIFT); push('keyreleased','Left Shift'); frame()
  take('\27[57441;2u\27[97:65;2;65u\27[97;2:3u\27[57441;1:3u')
  t:feed('\27[<u\27[?2004h'); local clipboard=system.get_clipboard; system.get_clipboard=function() return 'paste\n' end
  -- The controller holds its clipboard callback, so replace that callback too.
  view.input.clipboard=system.get_clipboard
  push('keypressed','Left GUI',terminal.SUPER); push('keypressed','V',terminal.SUPER)
  push('textinput',nil,0,'v'); push('keyreleased','V',terminal.SUPER); push('keyreleased','Left GUI'); frame()
  take('\27[200~paste\n\27[201~'); system.get_clipboard=clipboard
  -- A focus event must preserve the first key queued after it.
  system._test_event{type='focus',focused=1}; push('keypressed','B'); push('textinput',nil,0,'b'); push('keyreleased','B'); frame(); take('b')
  t:feed('\27[?1000;1006h'); view:scroll_to_bottom(); frame()
  system._test_event{type='mousepressed',button=1,x=math.floor(view.position.x+view.cw*2+1),y=math.floor(view.position.y+view.lh*2+1)}
  system._test_event{type='mousereleased',button=1,x=math.floor(view.position.x+view.cw*2+1),y=math.floor(view.position.y+view.lh*2+1)}
  frame(); take('\27[<0;3;3M\27[<0;3;3m')
  system._test_event{type='mousewheel',amount=1,x=math.floor(view.position.x+view.cw*2+1),y=math.floor(view.position.y+view.lh*2+1)}
  frame(); take('\27[<64;3;3M')
  t:feed('\27[?1000l\27[2J\27[H\27[38;2;255;0;0;48;2;0;0;128m日é\27[0m'); view:sync(true)
  local row=view:visible_row(view.history_rows+1)
  assert(row.cells[1].text=='日' and row.cells[1].width==2 and row.cells[2].width==0 and row.cells[3].text=='é')
  local fg,bg=view:resolve_colors(row.cells[1]); assert(fg[1]==255 and fg[2]==0 and bg[3]==128)
  t:feed('\27[?1049hALT'); view:sync(true); assert(view.state.alternate and view.history_rows==0)
  t:feed('\27[?1049l'); view:sync(true); assert(not view.state.alternate and view:visible_row(view.history_rows+1).cells[1].text=='日')
  local shot=os.getenv('BMUX_NATIVE_PANE_SHOT')
  if shot then frame(); assert(system.save_screenshot(shot:gsub('%.bmp$','')..'-cells.bmp')) end
  local second <close> =terminal.new(80,24,0); local second_bytes={}
  local neighbor=View{terminal=second,send=function(s) second_bytes[#second_bytes+1]=s; return true end}
  core.root_view:open_view_in('right',neighbor); frame(); frame(); core.set_active_view(view)
  node=core.root_view:get_active_node()
  push('keypressed','Left Ctrl',terminal.CTRL); push('keypressed','Left Alt',terminal.CTRL|terminal.ALT)
  push('keypressed','Right',terminal.CTRL|terminal.ALT); push('keyreleased','Right',terminal.CTRL|terminal.ALT)
  push('keyreleased','Left Alt',terminal.CTRL); push('keyreleased','Left Ctrl'); frame()
  assert(core.active_view==neighbor,'reserved Ctrl-Alt pane chord stays application-owned')
  take(''); assert(#second_bytes==0); node:set_active_view(view); core.set_active_view(view)
  -- A real shell is driven only by the app's central pump/SDL wait; no uv.run
  -- or Lua output feed/read is used by this test.
  local live=View{cmd='/bin/sh',args={'-c',[[stty -echo; printf '\033[38;2;255;0;0mR\033[0mREADY\033]0;native-pane\007'; IFS= read -r line; printf '\r\nFINAL:%s' "$line"; exit 7]]}}
  node:add_view(live)
  local start=system.get_time()
  local function until_state(condition)
    repeat frame(); if condition() then return end; system.wait_event(0.05)
    until system.get_time()-start>5
    error('native pane deadline')
  end
  until_state(function() return live.title=='native-pane' end)
  assert(live.terminal:row(1).cells[1].style.fg==(terminal.COLOR_RGB|0xff0000))
  local first_revision=live.terminal:process_revision()
  for _,letter in ipairs{'p','a','y','l','o','a','d'} do push('keypressed',letter:upper()); push('textinput',nil,0,letter); push('keyreleased',letter:upper()) end
  push('keypressed','Return'); push('keyreleased','Return'); frame()
  until_state(function() return live.dead end)
  assert(live.terminal:process_state().exit_status==7 and live.terminal:process_revision()>first_revision)
  local found=false
  for y=1,live.rows do
    local chunks={}; for _,cell in ipairs(live.terminal:row(y).cells) do chunks[#chunks+1]=cell.text end
    if table.concat(chunks):find('FINAL:payload',1,true) then found=true end
  end
  assert(found,'final output survives process exit')
  frame(); assert(system.loop_stats().enabled)
  if shot then assert(system.save_screenshot(shot)) end
  live:try_close(function() end); core.set_active_view(view); node:set_active_view(view)
  assert(not keymap.modkeys.ctrl and not keymap.modkeys.shift,'modifier releases remain synchronized')
  print('Studio native pane: SDL input/IME, negotiated protocols, native grid/alt-screen, real shell/final output and central wakeup pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n'); rawset(_G,'STUDIO_BOOT_FAILED',true) end
require('core').quit(true)
