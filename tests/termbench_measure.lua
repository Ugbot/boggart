package.path='tools/?.lua;'..package.path
local m=require 'termbench.measure'
assert(loadfile('tools/termbench/studio_latency.lua'))
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
print('termbench measurement accounting: raw ordering, quantiles and stale/wrong/invalid frame rejection passed')
