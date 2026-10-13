package.path='tools/ghostty/?.lua;' .. package.path
local s,inputs,hash,json=require 'growth_support',require 'bitmap_cases',require 'hash_c',require 'json'
local M={report='tests/fixtures/ghostty-bitmap.json',fixture='tests/fixtures/ghostty-bitmap.h'}
local function number(v,max) assert(type(v)=='number' and v%1==0 and v>=0 and v<=max,'invalid SDK bitmap number'); return ('%d'):format(v) end
function M.render(r)
  local pin=s.decode('tools/ghostty/oracle-pin.json')
  assert(r.schema==1 and r.kind=='pinned-sdk-bitmap-allocator','invalid bitmap capture')
  for _,k in ipairs({'revision','archive_sha256','zig_version'}) do assert(r[k]==pin[k],'bitmap source pin mismatch') end
  for _,p in ipairs({'tools/ghostty/probe_bitmap.lua','tools/ghostty/bitmap_cases.lua','tools/ghostty/bitmap_probe.zig','tools/ghostty/growth_support.lua'}) do
    assert(r.identities[p]==s.sha(p),'bitmap capture source changed')
  end
  local source
  for _,m in ipairs(s.decode('THIRD_PARTY/ghostty-port.json').modules) do if m.upstream_path=='src/terminal/bitmap_allocator.zig' then source=m.sha256 end end
  assert(source and r.source_sha256==source,'SDK allocator source mismatch')
  local cases=inputs.cases()
  assert(s.same(r.cases,cases) and r.generated_cases_sha256==hash.sha256(inputs.generated(cases)),'allocator inputs changed')
  local lines={'/* Independent pinned SDK allocator placements and bitmaps. */',
    'static const struct { uint32_t capacity, chunk, first, count; } sdk_bitmap_cases[] = {'}
  local index=0
  for _,c in ipairs(cases) do lines[#lines+1]=('  {%s,%s,%d,%d},'):format(number(c.capacity,4294967295),number(c.chunk,32),index,#c.operations); index=index+#c.operations end
  assert(index==#r.events,'incomplete allocator capture')
  lines[#lines+1]='};'
  lines[#lines+1]='static const struct { unsigned operation, from, to; uint32_t bytes; bool success;'
  lines[#lines+1]='  uint32_t offset, words, search_start; uint64_t capacity, used, bits[8]; } sdk_bitmap_steps[] = {'
  index=0
  for _,c in ipairs(cases) do for step,op in ipairs(c.operations) do
    index=index+1; local e=r.events[index]
    assert(e.name==c.name and e.step==step-1,'allocator sequence drift')
    local masks={}; local words=math.ceil(c.capacity/(c.chunk*64))
    assert(#e.bitmaps==words and words<=8 and e.capacity==words*64*c.chunk,'invalid fixture bitmap capacity')
    assert(e.used<=e.capacity and e.used%c.chunk==0,'invalid SDK bitmap usage')
    for _,word in ipairs(e.bitmaps) do
      assert(type(word)=='string' and #word==16 and not word:find('[^%da-f]'),'unsafe bitmap literal')
      masks[#masks+1]='UINT64_C(0x' .. word .. ')'
    end
    local kind,from,to,bytes=0,0,0,0
    if op.allocate then kind,from,bytes=0,op.allocate.slot,op.allocate.bytes
    elseif op.free then kind,from=1,op.free
    elseif op.move then kind,from,to=2,op.move.from,op.move.to
    else kind,from=3,op.forget end
    local success=e.offset~=json.null
    assert(kind==0 or not success,'non-allocation has an offset')
    local offset=0
    if success then
      number(e.offset,4294967295); offset=e.offset
      assert(offset%c.chunk==0 and offset+math.ceil(bytes/c.chunk)*c.chunk<=e.capacity,'invalid SDK allocation extent')
    end
    lines[#lines+1]=('  {%d,%s,%s,%s,%s,%s,%d,%s,%s,%s,{%s}},'):format(kind,number(from,255),number(to,255),number(bytes,4294967295),
      tostring(success),number(offset,4294967295),#masks,number(e.search_start,#masks),
      number(e.capacity,4294967296),number(e.used,4294967296),table.concat(masks,','))
  end end
  lines[#lines+1]='};'; return table.concat(lines,'\n') .. '\n'
end
function M.output(r) return '/* SDK bitmap report SHA256: ' .. s.sha(M.report) .. ' */\n' .. M.render(r) end
if ...=='bitmap_fixture' then return M end
local ok,problem=xpcall(function()
  local args=boggart.args or {}; assert(#args==0 or (#args==1 and args[1]=='--check'))
  local output=M.output(s.decode(M.report))
  if #args==0 then s.write(M.fixture,output) else assert(s.read(M.fixture)==output,'stale C bitmap fixture') end
  print('SDK bitmap C fixture verified')
end,debug.traceback)
if not ok then io.stderr:write(tostring(problem),'\n'); return 1 end
return 0
