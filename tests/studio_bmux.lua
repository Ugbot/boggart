-- Real Studio controls, native shells, mode isolation and preserved split state.
local ok,err=xpcall(function()
  local core=require 'core';local shell=require 'shell';local command=require 'core.command'
  local terminal=require 'terminal';local style=require 'core.style';local View=require 'core.terminalview'
  local ws=require 'shell.workspaces.bmux'
  local function frame(n)
    for _=1,n or 3 do core.redraw=true;core.frame_start=system.get_time();core.step() end
  end
  local function leaves()return core.root_view.root_node:get_leaves()end
  local function tree()return leaves()[1]:get_content_root(core.root_view.root_node)end
  local function click_control(name)
    frame();local hit
    for _,r in ipairs(ws.toolbar.hits)do if r.item.command==name then hit=r;break end end
    assert(hit,'visible control '..name)
    core.on_event('mousepressed','left',hit.x+hit.w/2,hit.y+hit.h/2,1)
    core.on_event('mousereleased','left',hit.x+hit.w/2,hit.y+hit.h/2,1);frame()
  end
  local function click_mode(name)
    frame();local mb=shell.menubar;local hit
    for _,r in ipairs(mb:workspace_items())do if r.name==name then hit=r end end
    assert(hit,'visible mode '..name)
    local y=mb.position.y+mb.size.y-(style.font:get_height()+style.padding.y)/2
    core.on_event('mousepressed','left',hit.x+hit.w/2,y,1)
    core.on_event('mousereleased','left',hit.x+hit.w/2,y,1);frame()
    assert(shell.current==name,'workspace click switches '..name)
  end
  local function has_line(v,wanted)
    v:sync(true)
    for y=1,v.history_rows+v.rows do
      local text={};for _,cell in ipairs(v:visible_row(y).cells)do text[#text+1]=cell.text end
      if table.concat(text):gsub('%s+$','')==wanted then return true end
    end
  end
  local function until_true(check)
    local deadline=system.get_time()+5
    repeat frame(1);if check()then return end;system.wait_event(0.02)until system.get_time()>deadline
    error('native shell deadline')
  end
  local function key(name,mods,kind)
    system._test_event{type=kind or 'keypressed',key=name,modifiers=mods or 0}
  end
  assert(command.map['bmux:new-terminal'],'Bmux menu commands exist before mode entry')
  click_mode('bmux');local first=core.active_view
  assert(first:is(View) and first.terminal and not first.spawn_error,tostring(first.spawn_error))
  local first_pid=first.terminal:process_state().pid
  assert(#leaves()==1 and #leaves()[1].views==1,'first entry opens one shell')
  -- Actual SDL text/Return reaches a real interactive PTY.
  system._test_event{type='textinput',text="printf 'BMUX_LIVE\\n'"}
  key('Return');key('Return',0,'keyreleased');frame()
  until_true(function()return has_line(first,'BMUX_LIVE')end)
  first.terminal:feed('\27]7;file:///private/tmp\7');first:sync(true)
  click_control('bmux:new-terminal');local tab=core.active_view
  assert(tab~=first and #leaves()==1 and #leaves()[1].views==2,'new terminal opens a tab')
  assert(tab.bmux_cwd=='/private/tmp','new shell inherits decoded reported cwd')
  assert(tab.terminal:process_state().pid~=first_pid,'tabs own independent processes')
  local function command_key(name)
    key('Left GUI',terminal.SUPER);key(name,terminal.SUPER)
    key(name,terminal.SUPER,'keyreleased');key('Left GUI',0,'keyreleased');frame()
  end
  command_key('T');local shortcut_tab=core.active_view
  assert(shortcut_tab~=tab and #leaves()[1].views==3,'Cmd-T creates a terminal tab')
  command_key('W');assert(shortcut_tab.terminal==nil and core.active_view==tab,'Cmd-W closes only the active tab')
  click_control('bmux:split-right');local right=core.active_view
  click_control('bmux:split-down');local down=core.active_view
  assert(#leaves()==3 and tree().type=='hsplit' and tree().b.type=='vsplit','both split controls create shell panes')
  tree().divider=0.37;tree().b.divider=0.61;frame()
  local pids={first_pid,tab.terminal:process_state().pid,right.terminal:process_state().pid,down.terminal:process_state().pid}
  click_mode('edit');assert(not ws.toolbar.visible and #leaves()==1,'other mode isolates terminals and hides controls')
  first:send("printf 'BMUX_HIDDEN\\n'\n")
  click_mode('agent');click_mode('fleet');click_mode('bmux')
  assert(core.active_view==down and #leaves()==3,'mode roundtrip restores focused pane')
  assert(tree().divider==0.37 and tree().b.divider==0.61,'divider geometry survives')
  assert(tree().a.views[1]==first and tree().a.views[2]==tab,'tab identity/order survives')
  for i,v in ipairs{first,tab,right,down}do assert(v.terminal:process_state().pid==pids[i] and not v.dead,'live PTY survives mode switch')end
  until_true(function()return has_line(first,'BMUX_HIDDEN')end)
  click_control('bmux:zoom');assert(tree().zoomed and #leaves()==1,'zoom focuses pane')
  click_mode('agent');click_mode('bmux');assert(tree().zoomed and core.active_view==down,'zoom state survives')
  click_control('bmux:zoom');assert(#leaves()==3 and tree().a.views[1]==first,'unzoom restores hidden panes')
  click_control('bmux:next-pane');assert(core.active_view~=down and core.active_view:is(View),'next pane focuses a real terminal')
  core.set_active_view(down);frame();click_control('bmux:zoom');click_control('bmux:close-terminal')
  assert(down.terminal==nil and #leaves()==2,'close releases process and removes its pane')
  assert(tree():get_node_for_view(first) and tree():get_node_for_view(right),'closing zoomed pane keeps neighbours')
  click_control('bmux:zoom');click_control('bmux:split-right');local zoom_split=core.active_view
  assert(#leaves()==3 and tree():get_node_for_view(first),'splitting zoomed pane restores full tree')
  click_control('bmux:close-terminal');assert(zoom_split.terminal==nil and #leaves()==2)
  -- Mode commands stay app-owned even while the terminal owns raw keys.
  local mods=terminal.CTRL|terminal.ALT
  local function mode_key(number)
    key('Left Ctrl',terminal.CTRL);key('Left Alt',mods);key(number,mods)
    key(number,mods,'keyreleased');key('Left Alt',terminal.CTRL,'keyreleased');key('Left Ctrl',0,'keyreleased');frame()
  end
  mode_key('1');assert(shell.current=='agent','Ctrl-Alt-1 leaves raw terminal')
  mode_key('4');assert(shell.current=='bmux','Ctrl-Alt-4 enters Bmux')
  system.set_window_size(520,600);frame(5)
  assert(#ws.toolbar.hits==7,'narrow window keeps every control')
  for _,r in ipairs(ws.toolbar.hits)do
    assert(r.x>=ws.toolbar.position.x and r.x+r.w<=ws.toolbar.position.x+ws.toolbar.size.x+1,'control stays within width')
    assert(r.y+r.h<=ws.toolbar.position.y+ws.toolbar.size.y+1,'wrapped controls stay within height')
  end
  local mb=shell.menubar
  if mb.workspace_second_row then
    local item=mb:workspace_items()[4];assert(mb:workspace_at(item.x+1,mb.position.y+mb.size.y-1)=='bmux','wrapped mode hit remains usable')
  else
    local menu=mb:items();local last=menu[#menu];assert(mb:workspace_items()[1].x>last.x+last.w,'mode/menu controls do not overlap')
  end
  click_control('bmux:new-terminal');assert(core.active_view:is(View),'wrapped New terminal works')
  local shot=os.getenv('BMUX_MODE_SHOT');if shot then assert(system.save_screenshot(shot))end
  print('BMUX: visible mode/controls, SDL typing, live PTYs, tabs/splits/cwd, mode isolation, geometry/focus/zoom restore, close and narrow controls pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
