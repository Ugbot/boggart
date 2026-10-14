-- Native positioned clusters through retained SDL row commands.
local ok,err=xpcall(function()
  local terminal=require 'terminal'
  local color={255,255,255,255};local theme={foreground=color,background={0,0,0,255},palette={}}
  for i=0,15 do theme.palette[i]=color end
  local dir=assert(os.getenv('BMUX_RENDER_DIR'))
  local function bytes(path)local f=assert(io.open(path,'rb'));local s=f:read('a');f:close();return s end
  local function image(ctx,t,path,queued)
    local _,rows,history=t:geometry()
    renderer.begin_frame();renderer.set_clip_rect(0,0,10000,10000);renderer.draw_rect(0,0,10000,10000,{0,0,0,255})
    ctx:draw(17,20-history*20,9,20,history+1,history+rows)
    if queued then queued() end
    renderer.end_frame();assert(system.save_screenshot(path));return bytes(path)
  end
  for _,font_path in ipairs{'studio/data/fonts/monospace.ttf','tests/fixtures/fonts/NotoSansDevanagari.ttf'} do
    local font=assert(renderer.font.load(font_path,16))
    for mode=0,1 do
      local input=''
      for _,sgr in ipairs{'0','1','0;3','1;3'} do
        if input~='' then input=input..'\r\n' end
        input=input..'\27['..sgr..'mé x́ 👩‍💻 🇬🇧 ❤️ ⌚︎ क्ष कि X'
      end
      local a <close> =terminal.new(64,4,8);if mode==0 then a:feed('\27[?2027l') end;a:feed(input)
      local ca=renderer.new_terminal(font,a,theme);local expected=image(ca,a,dir..'/cluster-whole.bmp')
      for _,split in ipairs{1,2,3,#input//2,#input-1} do
        local b <close> =terminal.new(64,4,8);if mode==0 then b:feed('\27[?2027l') end
        b:feed(input:sub(1,split));b:feed(input:sub(split+1));local cb=renderer.new_terminal(font,b,theme)
        assert(image(cb,b,dir..'/cluster-split.bmp')==expected,'fragmented cluster pixels')
        getmetatable(cb).__gc(cb)
      end
      a:feed(mode==0 and '\27[?2027h' or '\27[?2027l')
      assert(image(ca,a,dir..'/cluster-mode.bmp')==expected,'existing cell widths survive mode changes')
      for i=1,6 do a:feed('\r\n'..i..' x́ क्ष 👩‍💻') end
      a:resize(43,3);a:ack_damage()
      expected=image(ca,a,dir..'/cluster-history.bmp')
      assert(image(ca,a,dir..'/cluster-close.bmp',function()a:feed('\27[Hchanged');a:close();getmetatable(ca).__gc(ca);collectgarbage('collect')end)==expected,'queued shaped rows survive mutation and closure')
    end
    getmetatable(font).__gc(font);getmetatable(font).__gc(font)
  end
  print('SDL clusters: both modes, fragmented styled text, retained widths, Indic/marks, history/reflow and queued closure pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
