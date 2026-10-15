local G=require('grapheme')
local Input=require('tui.input')
local clusters={'é','👩‍💻','👍🏽','🇬🇧','❤️','क्‍ष','क्ष'}
for _,cluster in ipairs(clusters) do
  local text='A'..cluster..'B';local stop=2+#cluster
  local offsets=G.boundaries(text)
  assert(#offsets==4 and offsets[1]==1 and offsets[2]==2 and offsets[3]==stop and offsets[4]==#text+1)
  assert(sys.cell_next(text,2)==stop and sys.cell_next(text,#text+1)==#text+1)
  for byte=2,stop-1 do assert(G.next(text,byte)==stop and G.snap(text,byte)==2) end
  assert(G.prev(text,stop)==2)
  for _,mode in ipairs({'paste','typing'}) do
    local box=Input.new()
    if mode=='paste' then box:paste(text)
    else for _,cp in utf8.codes(text) do box:key{key='char',char=utf8.char(cp)} end end
    local n=assert(utf8.len(cluster))
    assert(box.cursor==n+2 and box.line==text)
    box:key{key='left'};assert(box.cursor==n+1)
    box:key{key='left'};assert(box.cursor==1)
    box:key{key='right'};assert(box.cursor==n+1)
    box:key{key='backspace'};assert(box.line=='AB' and box.cursor==1)
    box:_set(text);box:key{key='home'};box:key{key='right'}
    box:key{key='delete'};assert(box.line=='AB' and box.cursor==1)
    box:_set(text);box:key{key='ctrl',char='a'};box:key{key='ctrl',char='f'}
    box:key{key='ctrl',char='f'};assert(box.cursor==n+1)
    box:key{key='ctrl',char='b'};assert(box.cursor==1)
  end
  local box=Input.new();box:paste(cluster..'X')
  local _,row,col=box:visual(8)
  assert(row==1 and col==2+sys.cell_width(cluster)+1)
  local runs,caret=box:runs(80);assert(caret==2+sys.cell_width(cluster)+1)
  local cells=box:_cells();assert(#cells==2 and cells[1].ch==cluster)
  box:key{key='ctrl',char='r'};box:key{key='char',char=cluster};box:key{key='backspace'}
  assert(box._search.q=='')
  local modal=Input.new{vim=true};modal:_set('A'..cluster..cluster..'B')
  modal:key{type='key',key='esc'}
  local function command(text) modal:key{type='key',key='char',char=text} end
  command('0');command('l');assert(modal.cursor==1)
  command('l');assert(modal.cursor==1+utf8.len(cluster))
  command('h');command('2');command('x');assert(modal.line=='AB')
  command('P');assert(modal.line=='A'..cluster..cluster..'B')
  command('u');assert(modal.line=='AB')
  modal:_set('A'..cluster..'B');modal.edit_mode='insert';modal:key{type='key',key='esc'};command('0');command('l');command('a')
  modal:key{type='key',key='char',char='X'};assert(modal.line=='A'..cluster..'XB')
  modal:key{type='key',key='esc'};command('0');command('/')
  command(cluster);modal:key{type='key',key='enter'};assert(modal.cursor==1)
  command('/');command(cluster);modal:key{type='key',key='backspace'}
  assert(modal._va._vs.prompt.text=='');modal:key{type='key',key='esc'}
end
local capped='e'..string.rep('́',100)
assert(G.next(capped..'X',1)==#capped+1)
local controls='a\ńb\tX\0Y';local offsets=G.boundaries(controls)
assert(G.next(controls,1)==2 and G.next(controls,2)==3)
assert(G.next('a\ń',1)==2) -- Native plain-text iterator otherwise ignores LF.
assert(G.next('\255X',1)==2) -- Original malformed byte remains an editing unit.
assert(sys.cell_next('é\nX',1,4)==4)
for _,args in ipairs({{'x',0},{'x',3},{'x',1,3},{'x',2,1},{'x',1,-1}}) do
  assert(not pcall(sys.cell_next,table.unpack(args)))
end
local box=Input.new();box:paste('123\néX');box.cursor=3
box:key{key='down'};assert(box.cursor==7) -- Floor to the line-end cluster gap.
box:_set('a\ń');box.cursor=1;box:key{key='delete'}
assert(box.line=='á' and G.snap_cp(box.line,box.cursor)==box.cursor)
box:_set('é👩‍💻🇬🇧X');local visual=box:visual(8)
for _,runs in ipairs(visual) do
  local body={};for i=2,#runs do body[#body+1]=runs[i].text end
  local text=table.concat(body);assert(not text:find('👩',1,true) or text:find('👩‍💻',1,true))
end
box:_set('👩‍💻🇬🇧❤️');local rows,caret_row,caret_col=box:visual(8)
assert(#rows==2 and caret_row==2 and caret_col==2,'full-width emoji row needs a continuation caret gap')
print('grapheme editing: native offsets, whole-cluster movement/deletion, controls, wrapping, search and public codepoint cursor pass')
