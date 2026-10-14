local core=require 'core'; local View=require 'core.terminalview'
local path=os.getenv('BOGGART_HOME')..'/native-vim.txt'
local file=assert(io.open(path,'wb')); file:write('vim native test\n'); file:close()
local view=View{cmd='/usr/bin/vim',args={'-Nu','NONE','-n','-i','NONE',path}}
core.root_view:get_active_node():add_view(view)
local function frame() core.frame_start=system.get_time(); core.step() end
local function wait_for(test)
  local start=system.get_time()
  repeat frame(); if test() then return end; system.wait_event(0.05) until system.get_time()-start>8
  error('native Vim deadline')
end
local function text()
  local lines={}
  for y=1,view.rows do local cells={}; for _,c in ipairs(view.terminal:row(y).cells) do cells[#cells+1]=c.text end; lines[#lines+1]=table.concat(cells) end
  return table.concat(lines,'\n')
end
local function key(name,commit)
  system._test_event{type='keypressed',key=name}
  if commit then system._test_event{type='textinput',text=commit} end
  system._test_event{type='keyreleased',key=name}
end
local ok,err=xpcall(function()
  wait_for(function() return view.state and view.state.alternate and text():find('vim native test',1,true) end)
  key('I','i'); system._test_event{type='textinput',text='HELLO_'}; frame()
  wait_for(function() return text():find('HELLO_vim native test',1,true) end)
  key('Escape'); system._test_event{type='textinput',text=':wq'}; key('Return'); frame()
  wait_for(function() return view.dead end)
  assert(view.terminal:process_state().exit_status==0 and not view.state.alternate)
  local result=assert(io.open(path,'rb')); local bytes=result:read('a'); result:close()
  assert(bytes=='HELLO_vim native test\n','SDL text reached Vim exactly once')
  view:try_close(function() end)
  print('actual Vim: native alternate-screen, SDL insert/escape/enter, exact saved text and normal exit pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n'); rawset(_G,'STUDIO_BOOT_FAILED',true) end
core.quit(true)
