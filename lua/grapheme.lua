-- Editing boundaries match the native Unicode16 effective cell clusters.
-- Controls (especially physical newlines/tabs) remain separate editing units.
-- Public positions are 1-based byte gaps. Codepoint conversion keeps the TUI's
-- existing cursor/voice-span API; it does not change what those offsets mean.
local M={}
local cache={}
function M.boundaries(s)
  for _,entry in ipairs(cache) do if entry.text==s then return entry.offsets end end
  local offsets={1};local pos=1
  while pos<=#s do
    local control=s:find('%c',pos);local stop=control or (#s+1)
    while pos<stop do
      local nextpos=sys.cell_next(s,pos,stop)
      assert(nextpos>pos,'native cluster iterator did not advance')
      pos=nextpos;offsets[#offsets+1]=pos
    end
    if control then pos=pos+1;offsets[#offsets+1]=pos end
  end
  if #s<=65536 then
    if #cache==4 then table.remove(cache,1) end
    cache[#cache+1]={text=s,offsets=offsets}
  end
  return offsets
end
local function locate(offsets,pos)
  local lo,hi=1,#offsets
  while lo<=hi do
    local mid=(lo+hi)//2
    if offsets[mid]<=pos then lo=mid+1 else hi=mid-1 end
  end
  return math.max(1,hi)
end
function M.snap(s,pos,forward)
  pos=math.max(1,math.min(pos,#s+1))
  local offsets=M.boundaries(s);local i=locate(offsets,pos)
  if forward and offsets[i]<pos then i=i+1 end
  return offsets[i]
end
function M.prev(s,pos)
  pos=math.max(1,math.min(pos,#s+1))
  local offsets=M.boundaries(s);local i=locate(offsets,pos)
  if offsets[i]==pos then i=math.max(1,i-1) end
  return offsets[i]
end
function M.next(s,pos)
  local offsets=M.boundaries(s);local i=locate(offsets,math.max(1,pos))
  return offsets[math.min(#offsets,i+1)]
end
function M.count(s) return #M.boundaries(s)-1 end
function M.byte(s,index)
  local offsets=M.boundaries(s)
  return offsets[math.max(1,math.min(index,#offsets))]
end
function M.index(s,byte,forward)
  local offsets=M.boundaries(s);local i=locate(offsets,math.max(1,math.min(byte,#s+1)))
  if forward and offsets[i]<byte then i=math.min(#offsets,i+1) end
  return i
end
function M.char(s,index) return s:sub(M.byte(s,index),M.byte(s,index+1)-1) end
function M.slice(s,from,to) return s:sub(M.byte(s,from),M.byte(s,to)-1) end
function M.units(s)
  local units={};local offsets=M.boundaries(s)
  for i=1,#offsets-1 do units[i]=s:sub(offsets[i],offsets[i+1]-1):lower() end
  return units
end
function M.byte_at(s,cp)
  if cp<=0 then return 1 end
  return utf8.offset(s,cp+1) or (#s+1)
end
function M.cp_at(s,byte)
  return assert(utf8.len(s,1,byte-1))
end
function M.snap_cp(s,cp,forward) return M.cp_at(s,M.snap(s,M.byte_at(s,cp),forward)) end
function M.prev_cp(s,cp) return M.cp_at(s,M.prev(s,M.byte_at(s,cp))) end
function M.next_cp(s,cp) return M.cp_at(s,M.next(s,M.byte_at(s,cp))) end
return M
