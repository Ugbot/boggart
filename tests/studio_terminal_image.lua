-- Same native glyph pipeline from immutable wire rows, without a client PTY.
local ok,why=xpcall(function()
  local core=require 'core';local style=require 'core.style';local terminal=require 'terminal';local json=require 'json'
  local View=require 'core.terminalview';local t=terminal.new(24,8,32);local reference=View{terminal=t}
  local theme=reference.render_theme;local font=style.code_font
  local image=renderer.terminal_image();local painted=renderer.new_terminal(font,image,theme)
  local cw,lh=font:get_width('M'),font:get_height();local directory=assert(os.getenv('BMUX_RENDER_DIR'))
  local function copy(v)return json.decode(json.encode(v))end
  local function view()
    local cols,rows,history=t:geometry();local tail=math.min(history,6);local screen,back={},{}
    for i=1,rows do screen[i]=t:row(i)end
    for i=1,tail do back[i]=t:row(history-tail+i,true)end
    return {cols=cols,rows=rows,screen=screen,scrollback={first=history-tail+1,total=history,rows=back}}
  end
  local serial=0
  local function data(path)local f=assert(io.open(path,'rb'));local b=f:read('a');f:close();return b end
  local function draw(context,first,last,y,queued)
    renderer.begin_frame();renderer.set_clip_rect(0,0,10000,10000);renderer.draw_rect(0,0,10000,10000,style.background)
    renderer.set_clip_rect(5,3,240,210);context:draw(9,y or 5,cw,lh,first,last)
    if queued then queued()end;renderer.end_frame()
  end
  local function parity(label,snapshot)
    snapshot=snapshot or view();assert(image:apply(snapshot));serial=serial+1
    local history=snapshot.scrollback.total;local tail=#snapshot.scrollback.rows;local total=tail+snapshot.rows
    local first=history-tail+1
    local a=directory..'/image-native-'..serial..'.bmp';local b=directory..'/image-wire-'..serial..'.bmp'
    draw(reference.render_context,first,history+snapshot.rows,5-(history-tail)*lh);assert(system.save_screenshot(a))
    draw(painted,1,total);assert(system.save_screenshot(b));assert(data(a)==data(b),'image pixel mismatch: '..label)
    return snapshot,b
  end
  t:feed('日é 👩‍💻 🇬🇧 ❤️\r\n\27[1;3;31;44mBOLD ITALIC\27[0m\r\n'..
    '\27[4:3;58;2;255;0;0mWAVE\27[0m\r\n\27]8;id=x;https://example.com\7LINK\27]8;;\7')
  local initial=parity('Unicode, style, links and wide cells')
  local captures=image:stats().captures;local cached=painted:stats().captures
  assert(image:apply(initial));draw(painted,1,8)
  assert(image:stats().captures==captures and painted:stats().captures==cached,'immutable row identity reuses native rows')
  t:feed('\27[2;1Hchanged');local changed=view()
  for i=1,8 do if i~=2 then changed.screen[i]=initial.screen[i]end end
  parity('single row update',changed)
  assert(image:stats().captures==captures+1 and painted:stats().captures==cached+1)
  local prior_generation=image:stats().generation;local baseline=directory..'/image-before-error.bmp'
  draw(painted,1,8);assert(system.save_screenshot(baseline))
  local broken=copy(changed);broken.screen[8].cells[24].width=9
  assert(not pcall(image.apply,image,broken));assert(image:stats().generation==prior_generation,'late malformed row did not publish')
  draw(painted,1,8);local after=directory..'/image-after-error.bmp';assert(system.save_screenshot(after));assert(data(baseline)==data(after))
  local sparse=copy(changed);sparse.screen[3]=nil;assert(not pcall(image.apply,image,sparse))
  local budget=copy(changed);budget.cols=4096;budget.rows=9;budget.screen[9]=copy(changed.screen[1]);assert(not pcall(image.apply,image,budget))
  local large=copy(changed);local huge=('x'):rep(65535)
  for _,row in ipairs(large.screen)do for _,cell in ipairs(row.cells)do cell.text=huge end end
  for _=1,3 do assert(not pcall(image.apply,image,large));assert(image:stats().generation==prior_generation)end
  -- New tables with equal contents preserve the native draw-row identities.
  assert(image:apply(copy(changed)));cached=painted:stats().captures;draw(painted,1,8);assert(painted:stats().captures==cached)
  for i=1,20 do t:feed('\r\nline '..i..' 🦊')end
  parity('bounded history tail');t:resize(17,6);parity('reflow')
  t:feed('\27[?1049hALT\27[41m screen');parity('alternate');t:feed('\27[?1049l');local final,shot=parity('primary restored')
  local expected=data(shot);draw(painted,1,#final.scrollback.rows+final.rows,5,function()
    image:close();getmetatable(painted).__gc(painted);t:close();collectgarbage('collect')
  end)
  local closed=directory..'/image-after-close.bmp';assert(system.save_screenshot(closed));assert(data(closed)==expected,'queued image rows survive all source/context closes')
  assert(not pcall(painted.draw,painted,0,0,cw,lh,1,1))
  assert(not pcall(image.apply,image,initial))
  local ownedfont=assert(renderer.font.load('studio/data/fonts/monospace.ttf',14))
  local fontimage=renderer.terminal_image();assert(fontimage:apply(initial))
  local fontcontext=renderer.new_terminal(ownedfont,fontimage,theme)
  draw(fontcontext,1,8,5,function()
    getmetatable(ownedfont).__gc(ownedfont)
    assert(not pcall(fontcontext.draw,fontcontext,0,0,cw,lh,1,1),'closed image font rejected')
    fontimage:close();getmetatable(fontcontext).__gc(fontcontext)
  end)
  -- Reentrancy/closure during staging must preserve native lifetimes.
  local old_step,old_pause=collectgarbage('param','stepsize'),collectgarbage('param','pause');local triggered=0
  for attempt=1,8 do
    collectgarbage('collect');collectgarbage('stop')
    local target=renderer.terminal_image();assert(target:apply(initial));local inside=false
    local candidate=copy(initial)
    do local garbage=setmetatable({},{__gc=function()if inside then triggered=triggered+1;target:close()end end})end
    collectgarbage('incremental');collectgarbage('param','stepsize',0);collectgarbage('param','pause',100);collectgarbage('restart')
    inside=true;local success,error_text=pcall(target.apply,target,candidate);inside=false
    assert(success or tostring(error_text):find('terminal image',1,true));target:close()
  end
  collectgarbage('param','stepsize',old_step);collectgarbage('param','pause',old_pause);collectgarbage('restart')
  assert(triggered>0,'image staging finalizers exercised')
  local interrupted=0
  for attempt=1,8 do
    collectgarbage('collect');collectgarbage('stop')
    local target=renderer.terminal_image();assert(target:apply(initial));local inside,nested=false,false
    local outer,inner=copy(initial),copy(initial);inner.screen[2].cells[1].text='N'
    do local garbage=setmetatable({},{__gc=function()if inside then target:apply(inner);nested=true end end})end
    collectgarbage('incremental');collectgarbage('param','stepsize',0);collectgarbage('param','pause',100);collectgarbage('restart')
    inside=true;local success,error_text=pcall(target.apply,target,outer);inside=false
    if nested then
      assert(debug.getuservalue(target,1)==inner,'outer apply overwrote reentrant image')
      if not success then interrupted=interrupted+1;assert(tostring(error_text):find('changed during apply',1,true))end
    else assert(success,tostring(error_text))end
    target:close()
  end
  collectgarbage('param','stepsize',old_step);collectgarbage('param','pause',old_pause);collectgarbage('restart')
  assert(interrupted>0,'reentrant commit guard exercised')
  print('studio_terminal_image: native/wire pixels, immutable cache, history/reflow, atomic rejection and deferred/finalizer lifetime pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(why),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
