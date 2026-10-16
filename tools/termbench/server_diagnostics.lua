-- Private benchmark overlay. Keep the production handler, policy, journal and
-- deadlines; retain bounded durations only, never bodies, tokens or payloads.
local control=assert(load(assert(boggart.embedded('control')),'@embedded:control'))()
if bog.mode~='serve'then return control end
local uv=require 'uv';local json=require 'json'
local rows,current,count={},nil,0
local delay=tonumber(os.getenv('BMUX_SYSTEM_ATTACH_DELAY_MS')or '0')
assert(delay and delay>=0 and delay<=1000 and delay%1==0,'invalid diagnostic attachment delay')
local listen=serve.listen
serve.listen=function(opts)
  local copy={};for k,v in pairs(opts)do copy[k]=v end
  copy.handler=function(req)
    count=count+1
    local row={method=req.method,path=req.path,start_ns=uv.hrtime(),capture_ns=0,captures=0,expire_ns=0,expires=0}
    current=row
    local result=table.pack(opts.handler(req))
    row.end_ns=uv.hrtime();row.elapsed_ns=row.end_ns-row.start_ns;row.status=result[1]
    if type(result[2])=='string'then row.response_bytes=#result[2]end
    current=nil;if #rows<512 then rows[#rows+1]=row end
    return table.unpack(result,1,result.n)
  end
  return listen(copy)
end
local start=control.start
control.start=function(...)
  local result=table.pack(start(...))
  if result[1]then
    local class=getmetatable(control.terminals.attachments)
    for _,name in ipairs{'capture','expire'}do
      local original=class[name]
      class[name]=function(...)
        local row=current;local begin=uv.hrtime();local out=table.pack(original(...))
        if name=='capture'and row then
          if delay>0 then uv.sleep(delay)end
        end
        if row then
          local key=name=='capture'and 'capture_ns'or 'expire_ns'
          local count=name=='capture'and 'captures'or 'expires'
          row[key]=row[key]+uv.hrtime()-begin;row[count]=row[count]+1
        end
        return table.unpack(out,1,out.n)
      end
    end
  end
  return table.unpack(result,1,result.n)
end
local stop=control.stop
control.stop=function(...)
  local f=assert(io.open(assert(os.getenv('BMUX_SYSTEM_SERVER_TRACE')),'wb'))
  assert(f:write(json.encode{pid=uv.os_getpid(),request_count=count,truncated=count>#rows,capture_delay_ms=delay,requests=rows},'\n'));assert(f:close())
  return stop(...)
end
return control
