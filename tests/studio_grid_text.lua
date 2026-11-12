-- Whole-string grid layout and the UI consumers that select its prefixes.
local ok,err=xpcall(function()
  local terminal=require 'terminal';local common=require 'core.common';local style=require 'core.style'
  local font=assert(renderer.font.load('studio/data/fonts/monospace.ttf',16));local cw=font:get_width('0')
  local color={255,255,255,255};local theme={foreground=color,background={0,0,0,255},palette={}}
  for i=0,15 do theme.palette[i]=color end
  local text='é👩‍💻🇬🇧日X';assert(sys.cell_width(text)==8 and sys.width('👩‍💻')==4)
  assert(sys.cell_width('👩‍💻')==2 and font:get_grid_width(text)==8*cw)
  local dir=assert(os.getenv('BMUX_RENDER_DIR'))
  local function bytes(path)local f=assert(io.open(path,'rb'));local s=f:read('a');f:close();return s end
  local function clear()renderer.begin_frame();renderer.set_clip_rect(0,0,10000,10000);renderer.draw_rect(0,0,10000,10000,{0,0,0,255})end
  for budget=0,10 do
    local head,used=sys.cell_take(text,budget);assert(used<=budget and sys.cell_width(head)==used)
    assert(font:get_grid_width(head)==used*cw)
    clear();local ending=renderer.draw_grid(font,head,17,20,color);assert(ending==17+used*cw);renderer.end_frame()
    assert(system.save_screenshot(dir..'/grid.bmp'));local actual=bytes(dir..'/grid.bmp')
    local t <close> =terminal.new(64,1,0);t:feed(head);local ctx=renderer.new_terminal(font,t,theme)
    clear();ctx:draw(17,20,cw,font:get_height(),1,1);renderer.end_frame();assert(system.save_screenshot(dir..'/grid-native.bmp'))
    assert(actual==bytes(dir..'/grid-native.bmp'),'prefix layout/paint/native agreement');getmetatable(ctx).__gc(ctx)
  end
  local prefix,used=sys.cell_take('👩‍💻X',1);assert(prefix=='' and used==0)
  assert(sys.cell_take('👩‍💻X',2)=='👩‍💻');assert(font:get_grid_width('a\0b')==2*cw)
  clear();assert(renderer.draw_grid(font,'a\0b',17,20,color)==17+2*cw);renderer.end_frame()
  -- Enqueued bytes and font caches survive explicit font closure until replay.
  clear();renderer.draw_grid(font,'x́X',17,20,color);renderer.end_frame();assert(system.save_screenshot(dir..'/grid-before-close.bmp'))
  clear();renderer.draw_grid(font,'x́X',17,20,color);getmetatable(font).__gc(font);renderer.end_frame()
  assert(system.save_screenshot(dir..'/grid-after-close.bmp'));assert(bytes(dir..'/grid-before-close.bmp')==bytes(dir..'/grid-after-close.bmp'))
  assert(not pcall(function()font:get_grid_width('x')end));getmetatable(font).__gc(font)
  -- Observe the real picker draw path with a deliberately narrow filename row.
  local Picker=require 'core.pickerview';local picker=Picker('file','.',function()end)
  picker.entries={{name='👩‍💻-é.txt',shown='👩‍💻-é.txt',dir=false}};picker.matches=nil
  picker.position.x,picker.position.y=0,0;picker.size.x,picker.size.y=style.code_font:get_width('0')*4+style.padding.x*2,400
  local old=common.draw_grid;local seen
  common.draw_grid=function(f,c,s,...)if s:sub(1,2)=='  ' then seen=s end;return old(f,c,s,...)end
  clear();picker:draw();renderer.end_frame();common.draw_grid=old
  assert(seen and not seen:find('👩') and seen:find('…',1,true),'narrow picker keeps emoji whole')
  local sandbox=require 'core.uisandbox';local f=style.code_font
  local ctx=sandbox.context({state={}},0,0,3*f:get_width('0'),100,nil,f)
  assert(ctx.text_width('👩‍💻')==2*f:get_width('0'))
  local truncated;common.draw_grid=function(ff,c,s,...)truncated=s;return old(ff,c,s,...)end
  clear();ctx.text('👩‍💻X',0,0);ctx.text('👩‍💻XX',0,30);renderer.end_frame();common.draw_grid=old
  assert(truncated=='👩‍💻…','sandbox prefix and draw use one policy')
  print('grid UI: whole prefixes, explicit lengths, native pixels, deferred font close, picker/sandbox truncation pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
