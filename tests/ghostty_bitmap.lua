package.path='tools/ghostty/?.lua;' .. package.path
local s,m,json=require 'growth_support',require 'bitmap_fixture',require 'json'
local report=s.decode(m.report)
assert(s.read(m.fixture)==m.output(report),'C bitmap fixture differs from independent SDK capture')
assert(#report.cases==11 and #report.events==1581,'incomplete SDK allocator coverage')
local last=report.events[#report.events]
assert(last.name=='fragmented_graphemes' and last.offset==json.null and last.used==8112 and last.capacity==8192,
  'missing independent SDK fragmentation failure')
local function reject(change)
  local copy=json.decode(s.encode(report)); change(copy)
  assert(not pcall(m.render,copy),'malformed or stale allocator capture accepted')
end
for _,field in ipairs({'revision','archive_sha256','zig_version','source_sha256','generated_cases_sha256'}) do
  reject(function(r) r[field]='changed' end)
end
reject(function(r) r.identities['tools/ghostty/bitmap_probe.zig']=string.rep('0',64) end)
reject(function(r) r.events[1].bitmaps[1]='0); system("injected");' end)
reject(function(r) r.events[1].offset=false end)
reject(function(r) r.events[1].offset=4294967296 end)
reject(function(r) r.events[1].search_start=100 end)
reject(function(r) table.remove(r.events) end)
reject(function(r) r.events[1].name='wrong' end)
reject(function(r) r.cases[1].capacity=-1 end)
print('SDK bitmap provenance, exact coverage, fragmentation and unsafe-input guards passed')
