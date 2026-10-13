package.path='tools/ghostty/?.lua;' .. package.path
local s,m=require 'growth_support',require 'growth_fixture'
local report=s.decode(m.report)
assert(s.read(m.fixture)==m.output(report),'compiled fixture differs from SDK capture')
local snapshots=0; for _,c in ipairs(report.c_abi_verification.wrap_head_row_checks) do snapshots=snapshots+c.snapshots end
assert(snapshots==89,'incomplete independent ABI coverage')
local dimensions,style_projection,gp_projection,fragmentation={},false,false,0
for _,e in ipairs(report.growth) do
  dimensions[e.dimension]=true
  style_projection=style_projection or e.after.styles>2*e.before.styles
  gp_projection=gp_projection or e.after.grapheme_bytes>2*e.before.grapheme_bytes
  if e.name=='sdk_grapheme_ascii_capacity_growth' then
    assert(e.grapheme_free_bytes==80 and e.largest_grapheme_free_run_bytes==48 and e.grapheme_entries<e.grapheme_map_capacity,
      'missing independent allocator fragmentation evidence')
    fragmentation=fragmentation+1
  end
end
for _,d in ipairs({'styles','grapheme_bytes','hyperlink_bytes','string_bytes'}) do assert(dimensions[d],'missing dimension coverage') end
assert(style_projection and gp_projection,'missing density projection coverage')
assert(fragmentation==3,'incomplete fragmentation capture')
local function reject(change)
  local copy=require('json').decode(s.encode(report)); change(copy)
  assert(not pcall(m.render,copy),'malformed or stale growth report accepted')
end
for _,field in ipairs({'revision','archive_sha256','driver_sha256','probe_sha256','support_sha256','generated_cases_sha256','original_pagelist_sha256'}) do
  reject(function(r) r[field]=string.rep('0',64) end)
end
reject(function(r) r.growth[#r.growth].shape.word_bytes=4 end)
reject(function(r) r.c_abi_verification.wrap_head_row_checks[1].snapshots=0 end)
reject(function(r) r.growth[1].before.styles='0}; system("injected");' end)
reject(function(r) r.growth[1].before.styles=false end)
reject(function(r) r.growth[1].before.styles=65536 end)
reject(function(r) r.growth[1].dimension='grow();' end)
reject(function(r) r.growth[1].used_rows=r.growth[1].before.rows+1 end)
reject(function(r) r.growth[1].after.injected=0 end)
reject(function(r) r.growth[1].shape.page_align=3 end)
print('SDK growth provenance, projection coverage and malformed-input guards passed')
