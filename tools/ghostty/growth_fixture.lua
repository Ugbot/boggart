-- Validate independently observed SDK growth and emit offline C expectations.
package.path='tools/ghostty/?.lua;' .. package.path
local s,hash=require 'growth_support',require 'hash_c'
local M={report='docs/benchmarks/2026-10-13-sdk-page-growth.json',fixture='tests/fixtures/ghostty-page-growth.h'}
local fields={'cols','rows','styles','hyperlink_bytes','grapheme_bytes','string_bytes'}
local dimensions={rehash='LP_GROW_REHASH',styles='LP_GROW_STYLES',grapheme_bytes='LP_GROW_GRAPHEMES',
  hyperlink_bytes='LP_GROW_HYPERLINKS',string_bytes='LP_GROW_STRINGS'}
local function number(n,limit)
  assert(type(n)=='number' and n%1==0 and n>=0 and n<=limit,'invalid SDK growth number')
  return ('%d'):format(n)
end
local function capacity(c)
  local known={}; for _,k in ipairs(fields) do known[k]=true end
  for k in pairs(c) do assert(known[k],'unknown capacity field') end
  local values={}
  for _,k in ipairs(fields) do values[#values+1]=number(c[k],(k=='grapheme_bytes' or k=='string_bytes') and 4294967295 or 65535) end
  return '{' .. table.concat(values,',') .. '}'
end
function M.render(r)
  local pin=s.decode('tools/ghostty/oracle-pin.json')
  assert(r.schema==1 and r.kind=='instrumented-sdk-page-growth','invalid growth report')
  for _,k in ipairs({'revision','archive_sha256','zig_version'}) do assert(r[k]==pin[k],'SDK growth pin mismatch') end
  assert(r.driver_sha256==s.sha('tools/ghostty/probe_page_growth.lua')
    and r.support_sha256==s.sha('tools/ghostty/growth_support.lua')
    and r.probe_sha256==s.sha('tools/ghostty/page_topology.zig'),'SDK capture source changed')
  local cases=s.cases()
  assert(r.generated_cases_sha256==hash.sha256(s.generated_cases(cases)) and s.same(r.inputs,cases),'SDK capture inputs changed')
  local ledger=s.decode('THIRD_PARTY/ghostty-port.json'); local original
  for _,m in ipairs(ledger.modules) do if m.upstream_path=='src/terminal/PageList.zig' then original=m.sha256 end end
  assert(original and r.original_pagelist_sha256==original,'SDK original source mismatch')
  local checks=r.c_abi_verification.wrap_head_row_checks
  assert(#r.growth>0 and #checks==#cases,'missing events or independent ABI checks')
  for i,c in ipairs(cases) do assert(checks[i].name==c.name and checks[i].snapshots==#c.operations+1,'incomplete ABI checks') end
  local metadata=r.c_abi_verification.manifest
  assert(metadata.schema==1 and metadata.revision==pin.revision and metadata.archive_sha256==pin.archive_sha256,'ABI source pin mismatch')
  local shape=r.growth[1].shape
  assert(shape.word_bytes==4 or shape.word_bytes==8,'invalid SDK word size')
  local known={page_align=true,cell_align=true,word_bytes=true}
  for k in pairs(shape) do assert(known[k],'unknown SDK shape field') end
  for _,k in ipairs({'page_align','cell_align'}) do
    number(shape[k],4294967295); local n=math.tointeger(shape[k]); assert(n>0 and (n & (n-1))==0,'invalid alignment')
  end
  assert(shape.cell_align>=8 and shape.page_align>=shape.cell_align,'invalid SDK shape')
  local lines={'/* Generated from real SDK PageList.increaseCapacity observations. */',
    ('static const lp_layout_shape sdk_growth_shape = {%d,%d,%d};'):format(shape.page_align,shape.cell_align,shape.word_bytes),
    'static const struct { lp_capacity before, after; lp_growth dimension;',
    '  uint32_t used; uint16_t rows; } sdk_growth_cases[] = {'}
  for _,e in ipairs(r.growth) do
    assert(s.same(e.shape,shape) and dimensions[e.dimension],'mixed shape or unknown growth dimension')
    local before,after=capacity(e.before),capacity(e.after)
    local rows=number(e.used_rows,65535); assert(e.used_rows<=e.before.rows,'used rows exceed capacity')
    for _,k in ipairs({'styles','grapheme_bytes','string_bytes','grapheme_entries','grapheme_map_capacity',
      'grapheme_free_bytes','largest_grapheme_free_run_bytes'}) do number(e[k],4294967295) end
    local used=e.dimension=='styles' and e.styles or e.dimension=='grapheme_bytes' and e.grapheme_bytes or 0
    lines[#lines+1]='  {' .. before .. ',' .. after .. ',' .. dimensions[e.dimension] .. ',' .. number(used,4294967295) .. ',' .. rows .. '},'
  end
  lines[#lines+1]='};'; return table.concat(lines,'\n') .. '\n'
end
function M.output(r) return '/* SDK growth report SHA256: ' .. s.sha(M.report) .. ' */\n' .. M.render(r) end
if ...=='growth_fixture' then return M end
local ok,problem=xpcall(function()
  local args=boggart.args or {}; assert(#args==0 or (#args==1 and args[1]=='--check'),'expected --check or no arguments')
  local output=M.output(s.decode(M.report))
  if #args==1 then assert(s.read(M.fixture)==output,'stale SDK growth fixture') else s.write(M.fixture,output) end
  print('SDK growth C fixture verified')
end,debug.traceback)
if not ok then io.stderr:write(tostring(problem),'\n'); return 1 end
return 0
