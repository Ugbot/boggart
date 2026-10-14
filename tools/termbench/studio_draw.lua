-- Actual Studio pane baseline/after capture. Run via BOGGART_STUDIO_SCRIPT.
local core=require 'core'; local protocol=require 'terminal'
local reference=os.getenv('BMUX_DRAW_REFERENCE')
local view_path=reference or 'studio/data/core/terminalview.lua'
local View=reference and assert(loadfile(reference))() or require 'core.terminalview'
local json=require 'json'; local hash=require 'hash_c'
local out=assert(os.getenv('BMUX_DRAW_REPORT'),'BMUX_DRAW_REPORT required')
local t <close> =protocol.new(80,24,2000)
local view=View{terminal=t,send=function() return true end}
local font_path='studio/data/fonts/monospace.ttf'
view.font=renderer.font.load(font_path,16); view.cw=view.font:get_width('M'); view.lh=view.font:get_height()
if view.render_context then view.render_context=renderer.new_terminal(view.font,t,view.render_theme) end
local reference_fonts,inside_row,current_style
if reference then
  reference_fonts={[0]=view.font}
  for flags=1,3 do reference_fonts[flags]=renderer.font.load(font_path,16,{bold=(flags&1)~=0,italic=(flags&2)~=0}) end
  local resolve,row=view.resolve_colors,view.draw_row
  function view:resolve_colors(cell)
    current_style=((cell.style.attrs&protocol.BOLD)~=0 and 1 or 0)|((cell.style.attrs&protocol.ITALIC)~=0 and 2 or 0)
    return resolve(self,cell)
  end
  function view:draw_row(...) inside_row=true; row(self,...); inside_row=false end
end
view.position.x,view.position.y=0,0; view.size.x,view.size.y=view.cw*80,view.lh*24
view.last_size.x,view.last_size.y=view.size.x,view.size.y
local corpora={plain=('abcdefgh0123456789'):rep(120),styled=('\27[38;2;120;30;200;48;5;17mHELLO\27[0m world '):rep(170),unicode=('日éΩ漢'):rep(480),
  mixed=('\27[0mA\27[1mB\27[3mI\27[1;3mC'):rep(600)}
local calls={rect=0,text=0}; local draw_rect,draw_text=renderer.draw_rect,renderer.draw_text
renderer.draw_rect=function(...) calls.rect=calls.rect+1; return draw_rect(...) end
renderer.draw_text=function(font,...) calls.text=calls.text+1; return draw_text(inside_row and reference_fonts[current_style] or font,...) end
local report={scope='actual Studio pane draw; CPU/wall time, not key-to-pixel latency',renderer=reference and 'native-lua-cells-reference' or 'native-row-commands',source=protocol.source(),samples={}}
local f=assert(io.open(view_path,'rb')); report.view_sha256=hash.sha256(f:read('a')); f:close()
local font_file=assert(io.open(font_path,'rb')); report.font={path=font_path,size=16,sha256=hash.sha256(font_file:read('a'))}; font_file:close()
report.reference_style_oracle=reference and 'independently loaded synthetic bold/italic fonts; saved frontend methods wrapped for matching pixels' or nil
if reference then assert(report.view_sha256=='362c7f1c3ad312978be0eefaf53d1371b72ba40e83a665384705834a2e95aee3','reference has changed') end
report.renderer_sources=renderer.terminal_sources()
for path,digest in pairs(report.renderer_sources) do
  local source=assert(io.open(path,'rb')); local actual=hash.sha256(source:read('a')); source:close()
  assert(actual==digest,'stale renderer binary: '..path)
end
local function frame()
  renderer.begin_frame(); core.clip_rect_stack[1]={0,0,view.size.x,view.size.y}
  renderer.set_clip_rect(0,0,view.size.x,view.size.y); view:draw(); renderer.end_frame()
end
for _,name in ipairs{'plain','styled','unicode','mixed'} do
  local data=corpora[name]
  t:reset(); t:feed(data); view:sync(true); view.scroll.y=0; view.scroll.to.y=0
  for _,mode in ipairs{'unchanged','one-row-dirty'} do
    if mode=='one-row-dirty' then view.scroll.y=math.max(0,view:get_scrollable_size()-view.size.y); view.scroll.to.y=view.scroll.y end
    local function change(i)
      if mode=='one-row-dirty' then t:feed('\27[H'..(i%2==0 and 'X' or 'Y')); view:sync(true) end
    end
    for i=1,6 do change(i); frame() end
    local before=view.render_context and view.render_context:stats()
    local wall,cpu={},{}; calls.rect,calls.text=0,0
    for i=1,21 do change(i); local c=os.clock(); local w=system.get_time(); frame(); wall[i]=(system.get_time()-w)*1e9; cpu[i]=(os.clock()-c)*1e9 end
    local after=view.render_context and view.render_context:stats()
    report.samples[#report.samples+1]={corpus=name,mode=mode,wall_ns=wall,cpu_ns=cpu,rect_calls=calls.rect,text_calls=calls.text,
      captures=after and after.captures-before.captures or nil,submissions=after and after.submissions-before.submissions or nil,
      last_frame_replay=renderer.terminal_replay_stats and renderer.terminal_replay_stats() or nil}
  end
end
renderer.draw_rect,renderer.draw_text=draw_rect,draw_text
local file=assert(io.open(out,'wb')); file:write(json.encode(report)); file:close()
print('Studio draw capture '..out); core.quit(true)
