-- Compare the C-only feed probe serially with alternating process order.
package.path='tools/ghostty/?.lua;' .. package.path
local s,hash=require 'growth_support',require 'hash_c'
local function main(args)
  assert(#args==3,'usage: BEFORE_BINARY AFTER_BINARY OUTPUT.json')
  local report={schema=1,kind='controlled-page-style-feed',before_revision='f9229ac',
    harness_sha256=s.sha('tools/termbench/style_feed.c'),driver_sha256=s.sha('tools/termbench/compare_style.lua'),
    lpage_after_sha256=s.sha('src/lpage.c'),lidmap_after_sha256=s.sha('src/lidmap.c'),
    before_binary_sha256=s.sha(args[1]),after_binary_sha256=s.sha(args[2]),
    samples_per_round=11,warmups=3,rounds=2,results={}}
  report.before_lpage_sha256=hash.sha256(s.run('git',{'show','f9229ac:src/lpage.c'}))
  report.library_compile_flags={'-O2','-g','-DNDEBUG','-std=gnu11'}
  report.harness_compile_flags={'-O2','-g','-DNDEBUG','-std=c11','-Wall','-Wextra','-Werror'}
  report.library_scope='All native archive objects are current except the baseline lpage.c.o, compiled from f9229ac with matching library flags.'
  report.memory_scope='Final lpage_usage allocated bytes; excludes terminal/parser, callbacks, allocator overhead, RSS and transaction peak.'
  local function median(values) table.sort(values); return values[math.floor(#values/2)+1] end
  for _,scenario in ipairs({'plain','sgr','unicode'}) do
    local result={scenario=scenario,before={},after={}}
    for round=1,2 do
      local order=round==1 and {'before','after'} or {'after','before'}
      for _,backend in ipairs(order) do
        local output=s.run(args[backend=='before' and 1 or 2],{scenario,'14'})
        local count=0
        for line in output:gmatch('[^\n]+') do
          local name,bytes,ns,allocated,digest=line:match('^(%w+) (%d+) (%d+) (%d+) (%d+)$')
          assert(name==scenario,'invalid C probe output'); count=count+1
          assert(not result.digest or result.digest==digest,'rendered state differs')
          result.digest=digest; result.bytes=tonumber(bytes)
          if count>3 then result[backend][#result[backend]+1]={ns=tonumber(ns),allocated=tonumber(allocated)} end
        end
        assert(count==14,'incomplete probe samples')
      end
    end
    local before,after={},{}
    for _,v in ipairs(result.before) do before[#before+1]=v.ns end
    for _,v in ipairs(result.after) do after[#after+1]=v.ns end
    result.before_median_ns=median(before); result.after_median_ns=median(after)
    report.results[#report.results+1]=result
    print(('%s: before %.3f ms, after %.3f ms; digest %s'):format(scenario,result.before_median_ns/1e6,result.after_median_ns/1e6,result.digest))
  end
  assert(s.sha('src/lpage.c')==report.lpage_after_sha256 and s.sha('src/lidmap.c')==report.lidmap_after_sha256,'source changed during probe')
  assert(s.sha(args[1])==report.before_binary_sha256 and s.sha(args[2])==report.after_binary_sha256,'probe binary changed')
  assert(s.sha('tools/termbench/style_feed.c')==report.harness_sha256 and s.sha('tools/termbench/compare_style.lua')==report.driver_sha256,'probe source changed')
  s.write(args[3],s.encode(report) .. '\n')
end
local ok,problem=xpcall(function() main(boggart.args or {}) end,debug.traceback)
if not ok then io.stderr:write(tostring(problem),'\n'); return 1 end
return 0
