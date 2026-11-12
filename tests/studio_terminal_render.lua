-- Reference pixels and native cache/deferred-lifetime checks through SDL3.
local ok,err=xpcall(function()
  local core=require 'core'; local terminal=require 'terminal'; local style=require 'core.style'
  local Reference=assert(loadfile('tools/termbench/reference/terminalview-native-lua.lua'))()
  local t <close> =terminal.new(24,8,12)
  local view=Reference{terminal=t}; local theme={foreground=style.text,background=style.background}
  -- The historical reference stays exact. Its cell calls use independently
  -- loaded synthetic option fonts as this increment's explicit style oracle.
  local fonts={}
  for flags=0,3 do fonts[flags]=renderer.font.load('studio/data/fonts/monospace.ttf',16,
    {bold=(flags&1)~=0,italic=(flags&2)~=0}) end
  view.font=fonts[0]; view.cw=view.font:get_width('M'); view.lh=view.font:get_height()
  local reference_row=view.draw_row
  function view:draw_row(row,x,y)
    local expected={}
    for _,cell in ipairs(row.cells) do
      if cell.width>0 and cell.text~='' and (cell.style.attrs&terminal.INVISIBLE)==0 then
        expected[#expected+1]=((cell.style.attrs&terminal.BOLD)~=0 and 1 or 0)|((cell.style.attrs&terminal.ITALIC)~=0 and 2 or 0)
      end
    end
    local draw_text=renderer.draw_text; local index=0
    renderer.draw_text=function(_,text,px,py,color) index=index+1; return draw_text(fonts[expected[index]],text,px,py,color) end
    local good,error_text=pcall(reference_row,self,row,x,y); renderer.draw_text=draw_text
    assert(good,error_text)
  end
  -- The reference palette is intentionally obtained through its color resolver.
  theme.palette={}; for i=0,15 do theme.palette[i]=view:resolve_colors{style={fg=terminal.COLOR_INDEXED|i,bg=0,underline=0,attrs=0}} end
  local native=renderer.new_terminal(view.font,t,theme)
  local dir=assert(os.getenv('BMUX_RENDER_DIR'))
  local function bytes(path) local f=assert(io.open(path,'rb')); local s=f:read('a'); f:close(); return s end
  local serial=0
  local function frame(use_native,first,last,x,y,clip,queued)
    renderer.begin_frame(); renderer.set_clip_rect(0,0,10000,10000)
    renderer.draw_rect(0,0,10000,10000,style.background)
    renderer.set_clip_rect(table.unpack(clip or {0,0,10000,10000}))
    if use_native then native:draw(x or 9,y or 5,view.cw,view.lh,first,last)
    else for row=first,last do view:draw_row(view:visible_row(row),x or 9,(y or 5)+(row-1)*view.lh) end end
    if queued then queued() end
    renderer.end_frame()
  end
  local function parity(label,first,last,x,y,clip)
    view:sync(true); first=first or 1; last=last or view.history_rows+view.rows
    serial=serial+1; local a=dir..'/ref-'..serial..'.bmp'; local b=dir..'/native-'..serial..'.bmp'
    renderer.set_clip_rect(0,0,10000,10000)
    renderer.show_debug(false)
    -- Alternating command forms causes full relevant damage without a test API.
    frame(false,first,last,x,y,clip); assert(system.save_screenshot(a))
    frame(true,first,last,x,y,clip); assert(system.save_screenshot(b))
    assert(bytes(a)==bytes(b),'native/reference pixel mismatch: '..label)
  end
  t:feed('plain 日é Ω\r\n\27[1;31;44mBOLD\27[2;7m INV\27[0m\r\n'..
    '\27[38;2;19;123;241;48;5;233mRGB\27[0m\r\n'..
    '\27[4:1;58;2;255;0;0mONE\27[4:2m TWO\27[4:3m WAVE\27[0m\r\n'..
    '\27[4:4mDOT\27[4:5m DASH\27[9;53m LINES\27[8m HIDDEN\27[0m\r\n'..
    '\27[3mITALIC Ag日é\27[0m\r\n\27[1;3mBOTH Ag日é\27[0m')
  parity('styles and single-scalar Unicode')
  local captures=native:stats().captures
  frame(true,1,8); frame(true,1,8)
  assert(native:stats().captures==captures,'unchanged rows are reused')
  t:feed('\27[2;2Hchanged'); t:ack_damage(); frame(true,1,8)
  assert(native:stats().captures==captures+1,'row revisions survive damage acknowledgement')
  local replay=renderer.terminal_replay_stats()
  assert(replay.rows_skipped>0 and replay.rows_replayed<replay.rows_queued,'partial damage skips rows outside the dirty region')
  assert(system.save_screenshot(dir..'/partial-native.bmp'))
  assert(view.screen_rows[2].cells[2].text~=t:row(2).cells[2].text,'reference cache is stale after external damage acknowledgement')
  view.screen_rows={}; view.history_cache={}
  view:sync(true); frame(false,1,8); assert(system.save_screenshot(dir..'/partial-ref.bmp'))
  assert(bytes(dir..'/partial-native.bmp')==bytes(dir..'/partial-ref.bmp'),'native partial update preserves undamaged rows')
  parity('one damaged row',1,8)
  parity('fractional offset and clip',1,8,-4.5,-6.25,{11,13,133,93})
  parity('empty clip',1,8,nil,nil,{0,0,0,0})
  assert(renderer.terminal_replay_stats().rows_replayed==0,'empty clips replay no terminal rows')
  -- Scalar reference parity stays on its existing policy. The C cluster test
  -- covers shaping; use ASCII here to retain its independent overhang oracle.
  t:reset(); t:feed('\27[3mAg\27[1;3mG\27[4:3mWAVE\27[0m'); view:sync(true)
  local cw,lh=view.cw,view.lh; view.cw,view.lh=1,1
  parity('glyphs and decorations extending beyond tiny cells',1,8,17,80,{0,0,200,110})
  frame(true,1,8,17,80,{0,0,200,110}); frame(true,1,8,17,80,{0,0,200,110})
  t:feed('\27[8;1HG'); view:sync(true)
  frame(true,1,8,17,80,{0,0,200,110}); assert(system.save_screenshot(dir..'/overflow-native.bmp'))
  frame(false,1,8,17,80,{0,0,200,110}); assert(system.save_screenshot(dir..'/overflow-ref.bmp'))
  assert(bytes(dir..'/overflow-native.bmp')==bytes(dir..'/overflow-ref.bmp'),'changed glyph damage includes pixels beyond its cell')
  view.cw,view.lh=cw,lh
  t:feed('\27[2;1H\27[0mregular'); parity('return from styled atlases to regular',1,8)
  for i=1,20 do t:feed('\r\nline '..i..' 日') end
  parity('retained history',2,9,7,-view.lh)
  t:resize(31,6); parity('reflow and resize')
  t:feed('\27[?1049hALT\27[41m screen'); parity('alternate screen')
  t:feed('\27[?1049l'); parity('return to primary')
  -- Native rows own text/styles after enqueue, including an explicit source close.
  view:sync(true); local expected=dir..'/pending-ref.bmp'; local actual=dir..'/pending-native.bmp'
  local first,last=view.history_rows+1,view.history_rows+6; local offset=5-view.history_rows*view.lh
  frame(false,first,last,nil,offset); assert(system.save_screenshot(expected))
  frame(true,first,last,nil,offset,nil,function() t:feed('\27[HDESTROYED'); t:close(); getmetatable(native).__gc(native); collectgarbage('collect') end)
  assert(system.save_screenshot(actual)); assert(bytes(expected)==bytes(actual),'queued rows survive mutation/close/context finalization')
  assert(not pcall(function() native:draw(0,0,8,16,1,6) end),'closed context rejected')
  local fresh <close> =terminal.new(1,1,0)
  local ownedfont=renderer.font.load('studio/data/fonts/monospace.ttf',14)
  if ownedfont then
    local ctx=renderer.new_terminal(ownedfont,fresh,theme)
    fresh:feed('\27[1;3mA'); renderer.begin_frame(); ctx:draw(0,0,8,16,1,1)
    getmetatable(ownedfont).__gc(ownedfont)
    assert(not pcall(function() ctx:draw(0,0,8,16,1,1) end),'closed font rejected')
    getmetatable(ownedfont).__gc(ownedfont); renderer.end_frame()
  end
  print('SDL3 terminal rows: reference pixels, cache revisions, clip/scroll/reflow/alt, deferred mutation/close pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n'); rawset(_G,'STUDIO_BOOT_FAILED',true) end
require('core').quit(true)
