-- HTTP projection over the server registry; control retains auth/policy dispatch.
local json=require 'json';local M={}
local function response(value,why,status)
  return value and (status or 200) or why.status,json.encode(value or {error=why.message}),{content_type='application/json'}
end
local function object(req,allowed)
  local text=req.body or '{}';if text==''then text='{}'end
  local parsed,body=pcall(json.decode,text)
  if not parsed or type(body)~='table' or not text:match('^%s*{')then return nil,{status=400,message='JSON object required'}end
  if allowed then for key in pairs(body)do if not allowed[key]then return nil,{status=400,message='unknown terminal field'}end end end
  return body
end
local function query(control,req,allowed)
  local out=control.parse_query(req.query)
  for key,text in pairs(out)do
    if not allowed[key] or not text:match('^%d+$')then return nil,{status=400,message='invalid terminal query'}end
    out[key]=tonumber(text)
  end
  return out
end
function M.install(control)
  local function route(method,path,fn,description)
    control.route(method,path,function(req,id)
      if not control.terminals then return response(nil,{status=503,message='terminal host unavailable'})end
      return fn(control.terminals,req,id)
    end,description)
  end
  route('POST','/terminals',function(registry,req)
    local body,why=object(req);if not body then return response(nil,why)end
    local result,error=registry:open(body);return response(result,error,201)
  end,'create a server-owned terminal with literal argv/env/cwd')
  route('GET','/terminals',function(registry,req)
    local q,why=query(control,req,{offset=true,limit=true});if not q then return response(nil,why)end
    return response(registry:list(q.offset,q.limit))
  end,'list bounded server terminal metadata')
  route('GET','/terminals/([%w_-]+)',function(registry,_,id)return response(registry:get(id))end,'terminal native lifecycle and geometry')
  route('GET','/terminals/([%w_-]+)/screen',function(registry,req,id)
    local q,why=query(control,req,{first=true,count=true});if not q then return response(nil,why)end
    return response(registry:screen(id,q.first,q.count))
  end,'non-destructive bounded visible cell-grid page')
  for _,verb in ipairs{'input','resize','close'}do
    local allowed=verb=='input' and {generation=true,text=true} or verb=='resize' and {generation=true,cols=true,rows=true} or {generation=true}
    route('POST','/terminals/([%w_-]+)/'..verb,function(registry,req,id)
      local body,why=object(req,allowed);if not body then return response(nil,why)end
      if verb=='input'then return response(registry:write(id,body.generation,body.text))end
      if verb=='resize'then return response(registry:resize(id,body.generation,body.cols,body.rows))end
      return response(registry:close(id,body.generation))
    end,verb..' a terminal using its exact runtime generation')
  end
end
return M
