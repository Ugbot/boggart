-- Benchmark accounting only; no product imports or timing budgets.
local M={}
function M.summary(samples)
  assert(type(samples)=='table' and #samples>0,'samples required')
  local sorted={}
  for i,v in ipairs(samples)do
    assert(type(v)=='number' and v>=0 and v<math.huge,'invalid sample')
    sorted[i]=v
  end
  table.sort(sorted)
  local function percentile(p)return sorted[math.max(1,math.ceil(#sorted*p))]end
  return {count=#sorted,min=sorted[1],max=sorted[#sorted],p50=percentile(.5),
    p95=#sorted>=20 and percentile(.95)or nil,p99=#sorted>=100 and percentile(.99)or nil,
    quantile_method='nearest-rank; p95 requires 20 samples, p99 requires 100'}
end
function M.matches(frame,serial,sent,red)
  return frame.valid and frame.serial>serial and frame.ns>=sent
    and frame.rgba[1]==red and frame.rgba[2]==64 and frame.rgba[3]==192 and frame.rgba[4]==255
end
function M.startup_phases(log,spawned,presented)
  local names={'main_enter','sdl_initialized','window_created','renderer_initialized',
    'libraries_opened','harness_booted','assets_registered','core_required','core_initialized','run_enter'}
  local json=require 'json';local rows={};local previous=spawned
  assert(presented>=spawned,'presentation precedes spawn')
  for line in log:gmatch('[^\r\n]+')do
    local encoded=line:match('^BMUX_STARTUP (.*)$')
    if encoded then
      local row=assert(json.decode(encoded),'invalid startup trace JSON')
      assert(row.phase==names[#rows+1]and #rows<#names,'unexpected startup phase')
      assert(math.type(row.ns)=='integer'and row.ns>=previous and row.ns<=presented,'invalid startup timestamp')
      rows[#rows+1]={phase=row.phase,ns=row.ns,elapsed_ns=row.ns-previous};previous=row.ns
    end
  end
  assert(#rows==#names,'incomplete startup trace')
  rows[#rows+1]={phase='first_terminal_present',ns=presented,elapsed_ns=presented-previous}
  return rows
end
function M.resources(before,after,roles)
  local prior,seen,rows,groups={},{},{},{}
  assert(#before.processes==#after.processes,'process count changed during idle sample')
  for _,p in ipairs(before.processes)do assert(not prior[p.pid],'duplicate PID');prior[p.pid]=p end
  for _,p in ipairs(after.processes)do
    local b=assert(prior[p.pid],'idle PID changed')
    assert(not seen[p.pid]and p.start_ticks==b.start_ticks,'PID reused or duplicated');seen[p.pid]=true
    local dt=p.sampled_ns-b.sampled_ns;local cpu=p.user_ns+p.system_ns-b.user_ns-b.system_ns
    assert(dt>0 and p.user_ns>=b.user_ns and p.system_ns>=b.system_ns,'nonmonotonic process sample')
    local role=assert(roles[p.pid],'unclassified benchmark PID')
    local row={pid=p.pid,role=role,interval_ns=dt,cpu_ns=cpu,cpu_percent=100*cpu/dt,
      rss_start_bytes=b.rss_bytes,rss_end_bytes=p.rss_bytes}
    rows[#rows+1]=row
    local g=groups[role]or {count=0,cpu_ns=0,cpu_percent=0,rss_start_bytes=0,rss_end_bytes=0};groups[role]=g
    g.count=g.count+1;g.cpu_ns=g.cpu_ns+cpu;g.cpu_percent=g.cpu_percent+row.cpu_percent
    g.rss_start_bytes=g.rss_start_bytes+b.rss_bytes;g.rss_end_bytes=g.rss_end_bytes+p.rss_bytes
  end
  return {processes=rows,roles=groups}
end
return M
