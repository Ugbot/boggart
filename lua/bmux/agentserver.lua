-- Existing native authentication and control capability dispatch guard each route.
local json=require 'json';local M={}
local function response(value,why,status)
  return value and (status or 200)or why.status,json.encode(value or {error=why.message,receipt=why.receipt}),{content_type='application/json'}
end
function M.install(control)
  local function route(method,path,fn,description)
    control.route(method,path,function(req)
      if not control.fleet then return response(nil,{status=503,message='Fleet host unavailable'})end
      if req.query and req.query~=''then return response(nil,{status=400,message='Fleet query parameters unsupported'})end
      return fn(control.fleet,req)
    end,description)
  end
  route('GET','/fleet',function(host)
    local body,why=host:encoded();if not body then return response(nil,why)end
    return 200,body,{content_type='application/json'}
  end,'read copied server Fleet metadata and actual runtime capabilities')
  route('GET','/fleet/stream',function(host)
    local body,why=host:encoded();if not body then return response(nil,why)end
    return 'stream',host.channel,body
  end,'observe server Fleet snapshots on a dedicated native channel')
  for _,name in ipairs{'launch','commands'}do
    route('POST','/fleet/'..name,function(host,req)
      local text=req.body or ''
      if #text>65536 or not text:match('^%s*{')then return response(nil,{status=400,message='bounded Fleet command object required'})end
      local parsed,body=pcall(json.decode,text)
      if not parsed then return response(nil,{status=400,message='invalid Fleet command JSON'})end
      return response(host:submit(name,body))
    end,name=='launch'and 'launch a single server-owned native agent with literal argv' or 'route a sequence-checked action to the exact live agent runtime')
  end
end
return M
