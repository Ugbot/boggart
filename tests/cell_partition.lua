local cases={'éX','👩‍💻X','🇬🇧X','❤️X','⌚︎X'}
for _,text in ipairs(cases)do
  local cluster=sys.cell_first(text);assert(cluster==text:sub(1,-2))
  for cut=1,#cluster do
    local parts=sys.cell_partition(text,{cut,#text})
    assert(#parts==2 and parts[1][1]==1 and parts[1][2]==cluster and parts[2][1]==2 and parts[2][2]=='X')
  end
end
local text='e'..('́'):rep(100)..'X';local cluster=sys.cell_first(text)
assert(cluster==text:sub(1,-2) and sys.cell_width(cluster)==1)
local spans=sys.cell_partition(text,{1,#text});assert(spans[1][2]==cluster and spans[2][2]=='X')
assert(sys.cell_partition('X',{0,1,1})[1][1]==2)
assert(#sys.cell_partition('',{})==0 and sys.cell_first('')=='')
assert(sys.cell_first('a\0b')=='a\0')
local malformed='\255\128X';local pieces=sys.cell_partition(malformed,{1,2,3})
assert(#pieces==3 and pieces[1][2]=='\255' and pieces[2][2]=='\128' and pieces[3][2]=='X')
for _,ends in ipairs{{1},{2,1},{5},{-1,3}}do assert(not pcall(sys.cell_partition,'abc',ends))end
assert(not pcall(sys.cell_partition,'abc',false))
print('cell partition: head ownership across byte/style boundaries, exact capped/ignored/malformed bytes and validation pass')
