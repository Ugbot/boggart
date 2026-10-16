-- Authentication and capability policy remain in control.dispatch.
local json = require 'json'
local M = {}
function M.options(terminals,server)
  return {changed=function(snapshot)
    local channel='layout:'..snapshot.host_id
    if server:clients(channel)>0 then server:broadcast('message',json.encode(snapshot),channel) end
  end,resolve=function(view)
    if view.kind=='terminal' then
      local entry,why=terminals:find(view.terminal_id,view.generation)
      if not entry then return nil,why end
      if entry.closed then return nil,{status=409,message='terminal grid is closed'} end
      return true
    end
    for _,record in ipairs(require('fleet').default:records()) do
      if record.id==view.agent_id then return true end
    end
    return nil,{status=404,message='unknown Fleet agent'}
  end}
end
function M.new(terminals,server)return require('bmux.layout').new(M.options(terminals,server))end
local function response(value, why)
  return value and 200 or why.status, json.encode(value or {error=why.message}),
    {content_type='application/json'}
end
function M.install(control)
  control.route('GET','/layout/session',function(req)
    if req.query and req.query~=''then return response(nil,{status=400,message='session query parameters unsupported'})end
    if not control.journal then return response({persistent=false})end
    local status=control.journal:status();status.persistent=true;return response(status)
  end,'inspect named SQLite checkpoint/recovery status without execution credentials')
  local function route(method, path, fn, description)
    control.route(method,path,function(req)
      if not control.layout then return response(nil,{status=503,message='layout host unavailable'}) end
      if req.query and req.query~='' then return response(nil,{status=400,message='layout query parameters unsupported'}) end
      return fn(control.layout,req)
    end,description)
  end
  route('GET','/layout',function(host) return response(host:snapshot()) end,
    'read the bounded server-owned workspace/surface/pane hierarchy')
  route('GET','/layout/stream',function(host)
    return 'stream','layout:'..host.host_id,json.encode(host:snapshot())
  end,'observe initial and committed layout snapshots on a dedicated native channel')
  route('POST','/layout/commands',function(host,req)
    local text=req.body or ''
    if #text>8192 or not text:match('^%s*{') then return response(nil,{status=400,message='layout command object required'}) end
    local parsed,body=pcall(json.decode,text)
    if not parsed then return response(nil,{status=400,message='invalid layout command JSON'}) end
    return response(host:command(body))
  end,'apply a validated layout command against an exact host identity and revision')
end
return M
