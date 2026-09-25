-- TZif v1/v2/v3 transition reader. Calendar matching uses UTC arithmetic,
-- never process-local TZ. Beyond the final explicit transition fail closed:
-- POSIX footer rules are intentionally not interpreted.
local M={}
local cache={}
local root="/usr/share/zoneinfo"
function M.configure(directory) assert(type(directory)=="string");root=directory;cache={} end
local function header(s,p)
 assert(s:sub(p,p+3)=='TZif','timezone_invalid')
 local v=s:sub(p+4,p+4)
 local a,b,c,d,e,f=string.unpack('>I4I4I4I4I4I4',s,p+20)
 return {gmt=a,std=b,leap=c,time=d,types=e,chars=f},v
end
local function size(h,w)return h.time*(w+1)+h.types*6+h.chars+h.leap*(w+4)+h.std+h.gmt end
function M.load(name)
 if cache[name]then return cache[name]end
 assert(type(name)=='string' and (name=='UTC' or name:match('^[%w_+-]+/[%w_+/-]+$')) and not name:find('..',1,true),'timezone_unsupported')
 if name=='UTC'then cache[name]={offset=function()return 0 end};return cache[name]end
 local f=assert(io.open(root..'/'..name,'rb'),'timezone_unavailable')
 local s=f:read('*a');f:close()
 local h,v=header(s,1);local p,w=45,4
 if v=='2' or v=='3' then local start=45+size(h,4);h=header(s,start);p=start+44;w=8 end
 local data_end=p+size(h,w)
 assert(h.leap==0,"timezone_leap_seconds_unsupported")
 local footer=s:sub(data_end):match("^\n([^\n]*)\n")
 local fixed
 if footer then
  local offset=footer:match("^<[%w+%-]+>([+%-]?%d+:?%d*:?%d*)$") or footer:match("^[%a]+([+%-]?%d+:?%d*:?%d*)$")
  if offset then
   local sign=offset:sub(1,1)=="-" and 1 or -1
   local hh,mm,ss=offset:match("^[+%-]?(%d+):?(%d*):?(%d*)$")
   fixed=sign*(tonumber(hh)*3600+(tonumber(mm) or 0)*60+(tonumber(ss) or 0))
  end
 end
 local transitions={};for i=1,h.time do transitions[i],p=string.unpack(w==8 and '>i8' or '>i4',s,p)end
 local indexes={};for i=1,h.time do indexes[i]=s:byte(p)+1;p=p+1 end
 local offsets={};for i=1,h.types do offsets[i],p=string.unpack('>i4',s,p);p=p+2 end
 local function offset(t)
  if #transitions>0 and t>transitions[#transitions] then
   assert(fixed~=nil,'timezone_horizon_exceeded');return fixed
  end
  local lo,hi=1,#transitions;local n=0
  while lo<=hi do local mid=(lo+hi)//2;if transitions[mid]<=t then n=mid;lo=mid+1 else hi=mid-1 end end
  return offsets[n==0 and 1 or indexes[n]]
 end
 local min,max=offsets[1],offsets[1];for _,value in ipairs(offsets) do min=math.min(min,value);max=math.max(max,value) end
 cache[name]={offset=offset,fold_window=max-min};return cache[name]
end
-- First physical occurrence of a civil minute wins during folds; gaps skip.
function M.next(at,zone,after)
 local h,m=at:match('^(%d%d):(%d%d)$');h,m=tonumber(h),tonumber(m)
 assert(h and h<24 and m<60,'schedule_clock_invalid')
 local tz=M.load(zone)
 local start=(math.floor(after/60)+1)*60
 for t=start,start+3*86400,60 do
  local civil=t+tz.offset(t);local d=os.date('!*t',civil)
  if d.hour==h and d.min==m then
   local first=true
   for previous=t-math.ceil((tz.fold_window or 0)/60)*60,t-60,60 do
    if previous+tz.offset(previous)==civil then first=false;break end
   end
   if first then return t end
  end
 end
 error('schedule_next_unavailable')
end
return M
