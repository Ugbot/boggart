local uv=require 'uv'
local Terminal=require 'terminal'
local fixture=assert(os.getenv('BMUX_BENCH_FIXTURE'))
local t <close> =assert(Terminal.open{cmd=fixture,cols=80,rows=24,history=0})
local function pixel(red)
  local until_at=uv.hrtime()+3000000000
  repeat
    uv.run('nowait')
    local cell=t:row(1).cells[1]
    if cell and cell.style.bg==(Terminal.COLOR_RGB|(red<<16)|(64<<8)|192)then return end
    uv.sleep(1)
  until uv.hrtime()>until_at
  error('PTY fixture did not paint expected RGB '..red)
end
pixel(0)
for _,byte in ipairs{65,90,1,255,0,32}do
  assert(t:write(string.char(byte)));pixel(byte)
end
assert(not t:process_state().exited)
print('termbench fixture: raw PTY bytes, distinct native RGB and liveness passed')
