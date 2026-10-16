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
return M
