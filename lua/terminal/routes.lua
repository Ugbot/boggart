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
    control.route(method,path,function(req,...)
      if not control.terminals then return response(nil,{status=503,message='terminal host unavailable'})end
      return fn(control.terminals,req,...)
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
    local allowed=verb=='input' and {generation=true,text=true,attachment_id=true,attachment_token=true,control_token=true,command_seq=true}
      or verb=='resize' and {generation=true,cols=true,rows=true,attachment_id=true,attachment_token=true,control_token=true,command_seq=true} or {generation=true}
    route('POST','/terminals/([%w_-]+)/'..verb,function(registry,req,id)
      local body,why=object(req,allowed);if not body then return response(nil,why)end
      if verb=='input'then return response(registry:write(id,body.generation,body.text,body))end
      if verb=='resize'then return response(registry:resize(id,body.generation,body.cols,body.rows,body))end
      return response(registry:close(id,body.generation))
    end,verb..' a terminal using its exact runtime generation')
  end
  local function attached(method,pattern,allowed,fn,description)
    route(method,pattern,function(registry,req,id,attachment_id)
      local body,why=object(req,allowed);if not body then return response(nil,why)end
      if type(body.generation)~='number' or body.generation%1~=0 or body.generation<1 then return response(nil,{status=400,message='terminal generation required'})end
      local entry,error=registry:find(id,body.generation);if not entry then return response(nil,error)end
      if attachment_id then body.attachment_id=attachment_id end
      local encoded,failure=fn(registry.attachments,entry,body)
      if not encoded then return response(nil,failure)end
      return 200,encoded,{content_type='application/json'}
    end,description)
  end
  attached('POST','/terminals/([%w_-]+)/attachments',{generation=true,tail=true},
    function(host,entry,body)return host:attach(entry,body)end,'attach a read-only client with a frozen grid/tail and independent cursor')
  local prefix='/terminals/([%w_-]+)/attachments/([%w_-]+)'
  attached('POST',prefix..'/updates',{generation=true,attachment_token=true,after=true,control_token=true},
    function(host,entry,body)return host:updates(entry,body)end,'read independent terminal deltas or retry the last immutable frame')
  attached('POST',prefix..'/control',{generation=true,attachment_token=true,control_token=true,takeover=true},
    function(host,entry,body)return host:control(entry,body)end,'explicitly acquire, renew or take over the input/resize lease')
  attached('POST',prefix..'/detach',{generation=true,attachment_token=true},
    function(host,entry,body)return host:detach(entry,body)end,'detach a viewer without closing the terminal')
end
return M
