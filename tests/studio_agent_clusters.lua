local ok,err=xpcall(function()
  local Agent=require 'core.agentview';local terminal=require 'terminal';local style=require 'core.style'
  local view=Agent();view.entries={};local font=style.code_font;local cw=font:get_grid_width('0');local ch=font:get_height()
  local dir=assert(os.getenv('BMUX_RENDER_DIR'))
  local function bytes(path)local f=assert(io.open(path,'rb'));local s=f:read('a');f:close();return s end
  local function clear()
    require('core').clip_rect_stack={{0,0,10000,10000}}
    renderer.begin_frame();renderer.set_clip_rect(0,0,10000,10000);renderer.draw_rect(0,0,10000,10000,{0,0,0,255})
  end
  local theme={foreground=style.text,background=style.background,palette={}};for i=0,15 do theme.palette[i]=style.text end
  for _,text in ipairs{'e**́**X','👩**‍💻**X','🇬**🇧**X','❤️X'}do
    local entry={role='assistant',text=text};local rows=view:layout(entry,80)
    local t <close> =terminal.new(128,#rows,0);local plain={}
    clear()
    for i,row in ipairs(rows)do
      local x=17;local line={}
      for _,token in ipairs(row)do
        assert(not token.bold,'suffix style stays with cluster head')
        local col=token[1];t:feed(string.format('\27[38;2;%d;%d;%dm',col[1],col[2],col[3])..token[2])
        x=renderer.draw_grid(font,token[2],x,20+(i-1)*ch,col);line[#line+1]=token[2]
      end
      local joined=table.concat(line);assert(x==17+sys.cell_width(joined)*cw);plain[i]=joined
      if i<#rows then t:feed('\r\n')end
    end
    renderer.end_frame();assert(system.save_screenshot(dir..'/agent-grid.bmp'));local expected=bytes(dir..'/agent-grid.bmp')
    local ctx=renderer.new_terminal(font,t,theme)
    clear();ctx:draw(17,20,cw,ch,1,#rows);renderer.end_frame();assert(system.save_screenshot(dir..'/agent-native.bmp'))
    assert(bytes(dir..'/agent-native.bmp')==expected,'styled layout/grid/native pixel agreement');getmetatable(ctx).__gc(ctx)
    view.entries={entry};view.sel={a={e=1,r=1,c=0},b={e=1,r=#rows,c=sys.cell_width(plain[#rows])}}
    assert(view:selected_text()==table.concat(plain,'\n'),'selection preserves source text')
  end
  local entry={role='assistant',text='**e**́X'};local rows=view:layout(entry,1);local bold
  for _,row in ipairs(rows)do for _,token in ipairs(row)do if token[2]=='é' then bold=token.bold end end end
  assert(bold,'head emphasis survives cluster normalization')
  view.position.x,view.position.y=0,0;view.size.x,view.size.y=600,600;view.lines={'👩‍💻 é क्ष'};view.cx=1;view.cy=1
  view.entries={entry};clear();view:draw();renderer.end_frame()
  assert(system.save_screenshot(dir..'/agent-view.bmp'));local transcript=bytes(dir..'/agent-view.bmp')
  view.entries={};clear();view:draw();renderer.end_frame()
  assert(system.save_screenshot(dir..'/agent-empty.bmp'))
  assert(bytes(dir..'/agent-empty.bmp')~=transcript,'real transcript paints visible pixels')
  print('AgentView clusters: styled boundary ownership, grid/native pixels, source selection, narrow wrapping and real draw pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
