local core=require 'core'
local uv=require 'uv'
local function frame(color)
  local w,h=renderer.get_size()
  renderer.begin_frame()
  renderer.set_clip_rect(0,0,w,h)
  renderer.draw_rect(0,0,w,h,color)
  renderer.end_frame()
end
local ok,why=xpcall(function()
  local probe=system._test_present_probe
  assert(not probe().enabled and probe().serial==0)
  assert(not pcall(probe,-1,0))
  assert(not pcall(probe,math.maxinteger,0))
  assert(not pcall(probe,0,math.maxinteger))
  assert(not pcall(probe,0.5,0))
  -- First ShowWindow can change the HiDPI backing size and invalidate the
  -- retained cache. Stabilize that lifecycle before testing unchanged frames.
  for _=1,3 do frame{1,2,3,255}end
  probe(10,10)
  local before=uv.hrtime()
  frame{19,71,193,255}
  local first=probe()
  assert(first.enabled and first.valid and first.serial==1)
  assert(first.ns>=before and first.ns+first.readback_ns<=uv.hrtime())
  assert(first.readback_ns>0 and type(first.backend)=='string')
  assert(table.concat(first.rgba,',')=='19,71,193,255',table.concat(first.rgba,','))
  frame{19,71,193,255}
  assert(probe().serial==1,'unchanged scene must not manufacture a present')
  frame{211,53,97,255}
  local second=probe()
  assert(second.valid and second.serial==2 and second.ns>first.ns)
  assert(table.concat(second.rgba,',')=='211,53,97,255')
  probe(false);frame{13,17,23,255}
  assert(not probe().enabled and probe().serial==0 and not probe().valid)
end,debug.traceback)
if not ok then io.stderr:write(why,'\n');os.exit(1)end
print('Studio presentation probe: frames, RGB, clock and disabled/unchanged behavior passed')
core.quit(true)
