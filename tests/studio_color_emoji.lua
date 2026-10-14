-- Real Studio replay of colored glyphs and the same native terminal cell rows.
local ok,err=xpcall(function()
  local terminal=require 'terminal'
  local font=assert(renderer.font.load('studio/data/fonts/monospace.ttf',32))
  local cw,ch=font:get_grid_width('0'),font:get_height()
  local lines={
    'Smile and skin tone: 😀 👍🏽',
    'Joined emoji:        👩‍💻 👨‍👩‍👧‍👦',
    'Flag and keycap:     🇬🇧 1️⃣',
    'Emoji presentation:  ❤️',
    'Text presentation:   ©︎',
  }
  local color={12,220,100,255}
  local theme={foreground=color,background={0,0,0,255},palette={}}
  for i=0,15 do theme.palette[i]=color end
  local dir=assert(os.getenv('BMUX_RENDER_DIR'))
  local function bytes(path)local f=assert(io.open(path,'rb'));local b=f:read('a');f:close();return b end
  local function begin()
    renderer.begin_frame();renderer.set_clip_rect(0,0,10000,10000)
    renderer.draw_rect(0,0,10000,10000,{0,0,0,255})
  end
  local t <close> =terminal.new(48,#lines,0)
  t:feed(table.concat(lines,'\r\n'))
  local ctx=renderer.new_terminal(font,t,theme)
  begin();ctx:draw(24,40,cw,ch,1,#lines);renderer.end_frame()
  assert(system.save_screenshot(dir..'/emoji-native.bmp'))
  begin()
  for i,text in ipairs(lines) do
    assert(renderer.draw_grid(font,text,24,40+(i-1)*ch,color)==24+sys.cell_width(text)*cw)
  end
  renderer.end_frame();assert(system.save_screenshot(dir..'/emoji-grid.bmp'))
  assert(bytes(dir..'/emoji-native.bmp')==bytes(dir..'/emoji-grid.bmp'),'emoji grid/native replay pixels differ')
  getmetatable(ctx).__gc(ctx);getmetatable(font).__gc(font)
  print('Studio color emoji: native/grid replay, recorded cells, flags/ZWJ/skin tones/VS15/16 pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
