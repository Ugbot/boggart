package.path='tools/?.lua;'..package.path
local m=require 'termbench.measure'
assert(loadfile('tools/termbench/studio_latency.lua'))
assert(loadfile('tools/termbench/system.lua'))
assert(loadfile('tools/termbench/studio_system.lua'))
local raw={};for i=100,1,-1 do raw[#raw+1]=i end
local s=m.summary(raw)
assert(s.count==100 and s.min==1 and s.max==100 and s.p50==50 and s.p95==95 and s.p99==99)
assert(raw[1]==100,'summary preserves raw ordering')
assert(not m.summary{1,2,3}.p99 and not m.summary{1,2,3}.p95)
assert(not pcall(m.summary,{}))
assert(not pcall(m.summary,{0/0})and not pcall(m.summary,{math.huge})and not pcall(m.summary,{-1}))
local f={valid=true,serial=2,ns=101,rgba={65,64,192,255}}
assert(m.matches(f,1,100,65))
assert(not m.matches(f,2,100,65),'old present rejected')
assert(not m.matches(f,1,102,65),'pre-input present rejected')
assert(not m.matches(f,1,100,66),'wrong pixel rejected')
f.valid=false;assert(not m.matches(f,1,100,65),'failed readback rejected')
local before={processes={{pid=1,start_ticks=10,sampled_ns=100,user_ns=20,system_ns=10,rss_bytes=1000}}}
local after={processes={{pid=1,start_ticks=10,sampled_ns=200,user_ns=30,system_ns=15,rss_bytes=1200}}}
local u=m.resources(before,after,{[1]='server'})
assert(u.roles.server.cpu_ns==15 and u.roles.server.cpu_percent==15 and u.roles.server.rss_end_bytes==1200)
after.processes[1].start_ticks=11;assert(not pcall(m.resources,before,after,{[1]='server'}),'PID reuse rejected')
after.processes[1].start_ticks=10;after.processes[1].user_ns=19
assert(not pcall(m.resources,before,after,{[1]='server'}),'backwards CPU rejected')
after.processes[1].user_ns=30;assert(not pcall(m.resources,before,after,{}),'unclassified PID rejected')
local json=require 'json';local log={'ordinary app message'}
for i,name in ipairs{'main_enter','sdl_initialized','window_created','renderer_initialized',
  'libraries_opened','harness_booted','assets_registered','core_required','core_initialized','run_enter'}do
  log[#log+1]='BMUX_STARTUP '..json.encode{phase=name,ns=100+i*10}
end
local trace=table.concat(log,'\n')
local phases=m.startup_phases(trace,100,250);local total=0
for _,p in ipairs(phases)do total=total+p.elapsed_ns end
assert(#phases==11 and phases[1].elapsed_ns==10 and phases[11].elapsed_ns==50 and total==150)
assert(not pcall(m.startup_phases,'',100,250),'missing trace rejected')
assert(not pcall(m.startup_phases,trace..'\n'..log[2],100,250),'duplicate phase rejected')
assert(not pcall(m.startup_phases,trace,115,250),'pre-spawn timestamp rejected')
assert(not pcall(m.startup_phases,trace,100,150),'post-present timestamp rejected')
print('termbench measurement accounting: raw ordering, quantiles and stale/wrong/invalid frame rejection passed')
