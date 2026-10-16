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
print('termbench measurement accounting: raw ordering, quantiles and stale/wrong/invalid frame rejection passed')
