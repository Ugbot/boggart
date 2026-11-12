local M={}
local function allocation(slot,bytes) return {allocate={slot=slot,bytes=bytes}} end
local function release(slot) return {free=slot} end
function M.cases()
  local cases={}
  local function add(name,cap,chunk,ops) cases[#cases+1]={name=name,capacity=cap,chunk=chunk,operations=ops} end
  for _,chunk in ipairs({16,32}) do
    local ops={allocation(0,1),allocation(1,chunk+1),allocation(2,3*chunk),release(1),allocation(3,2*chunk),release(0),release(2),release(3)}
    add('small_' .. chunk,1,chunk,ops)
    add('word_boundary_' .. chunk,128*chunk,chunk,{
      allocation(0,63*chunk),allocation(1,2*chunk),release(0),allocation(2,64*chunk),release(1),release(2)})
    -- Fill word zero and check the hint rewinds when that word is freed.
    add('rewind_' .. chunk,128*chunk,chunk,{allocation(0,64*chunk),allocation(1,chunk),release(0),allocation(2,2*chunk)})
    add('multiword_' .. chunk,320*chunk,chunk,{allocation(0,5*chunk),allocation(1,65*chunk),allocation(2,128*chunk),release(1),allocation(3,70*chunk),release(2),release(3),release(0)})
    add('full_' .. chunk,64*chunk,chunk,{allocation(0,64*chunk),allocation(1,1),release(0),allocation(2,64*chunk)})
  end
  -- Repeat the SDK's realloc-before-free behavior for 128 grapheme clusters.
  local ops={}
  for cluster=0,125 do
    local slot=cluster%2
    for length=1,16 do
      if length==1 or (length-1)%4==0 then
        local temporary=128+slot
        ops[#ops+1]=allocation(temporary,length*4)
        if length>1 then ops[#ops+1]=release(slot) end
        -- Use a stable slot for the new allocation by generating a move in
        -- the probe input, keeping ownership until the next reallocation.
        ops[#ops+1]={move={from=temporary,to=slot}}
      end
    end
    ops[#ops+1]={forget=slot} -- cell retains it, so it stays allocated
  end
  for _,length in ipairs({1,5,9}) do
    ops[#ops+1]=allocation(128,length*4)
    if length>1 then ops[#ops+1]=release(0) end
    ops[#ops+1]={move={from=128,to=0}}
  end
  ops[#ops+1]=allocation(128,13*4) -- 80 free bytes, no 64-byte span
  add('fragmented_graphemes',8192,16,ops)
  return cases
end
function M.generated(cases)
  local lines={'pub const Operation = union(enum) { allocate: struct { slot: usize, bytes: u32 }, free: usize, move: struct { from: usize, to: usize }, forget: usize };',
    'pub const Case = struct { name: []const u8, capacity: u32, chunk: u32, operations: []const Operation };',
    'pub const cases = [_]Case{'}
  local function integer(n,max) assert(type(n)=='number' and n%1==0 and n>=0 and n<=max); return ('%d'):format(n) end
  local function literal(t) return '"' .. t:gsub('.',function(c) return ('\\x%02x'):format(c:byte()) end) .. '"' end
  for _,c in ipairs(cases) do
    assert(c.chunk==16 or c.chunk==32)
    lines[#lines+1]=('.{ .name=%s, .capacity=%s, .chunk=%d, .operations=&.{'):format(literal(c.name),integer(c.capacity,4294967295),c.chunk)
    for _,op in ipairs(c.operations) do
      if op.allocate then
        assert(op.allocate.bytes>0)
        lines[#lines+1]=('.{ .allocate=.{ .slot=%s, .bytes=%s } },'):format(integer(op.allocate.slot,255),integer(op.allocate.bytes,4294967295))
      elseif op.free then lines[#lines+1]='.{ .free=' .. integer(op.free,255) .. ' },'
      elseif op.move then lines[#lines+1]=('.{ .move=.{ .from=%s, .to=%s } },'):format(integer(op.move.from,255),integer(op.move.to,255))
      else lines[#lines+1]='.{ .forget=' .. integer(op.forget,255) .. ' },' end
    end
    lines[#lines+1]='} },'
  end
  lines[#lines+1]='};'; return table.concat(lines,'\n') .. '\n'
end
return M
