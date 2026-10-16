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
  local function session_status(include_archive)
    local status=control.journal and control.journal:status()or{}
    if not include_archive then status.last_recovery=nil end
    status.persistent=control.journal~=nil;status.host_id=control.layout.host_id;return status
  end
  control.route('GET','/layout/session/recovery/status',function(req)
    if req.query and req.query~=''then return response(nil,{status=400,message='recovery query parameters unsupported'})end
    if not control.layout then return response(nil,{status=503,message='layout host unavailable'})end
    return response(session_status(true))
  end,'observe recovery completion and archive metadata without changing a preview or replaying a write')
  control.route('GET','/layout/session/recovery',function(req)
    if req.query and req.query~=''then return response(nil,{status=400,message='recovery query parameters unsupported'})end
    if not control.journal then return response(nil,{status=409,message='This server has no named saved session'})end
    return response(control.journal:recovery_preview())
  end,'preview explicit recovery of an owned blocked checkpoint without writing or starting processes')
  control.route('POST','/layout/session/recover',function(req)
    if req.query and req.query~=''then return response(nil,{status=400,message='recovery query parameters unsupported'})end
    if not control.journal then return response(nil,{status=409,message='This server has no named saved session'})end
    local raw=req.body or ''
    if #raw>4096 or not raw:match('^%s*{')then return response(nil,{status=400,message='bounded recovery command object required'})end
    local decoded,body=pcall(json.decode,raw)
    if not decoded then return response(nil,{status=400,message='invalid recovery command JSON'})end
    local result,why=control.journal:recover(body)
    if result then result.status=session_status(true)end
    return response(result,why)
  end,'archive original bytes and resume saving the current layout under an exact owner and recovery preview')
  control.route('GET','/layout/checkpoint',function(req)
    if req.query and req.query~=''then return response(nil,{status=400,message='checkpoint query parameters unsupported'})end
    if not control.layout then return response(nil,{status=503,message='layout host unavailable'})end
    local cache={}
    if control.journal then for id,lines in pairs(control.journal.cache)do cache[id]=lines end end
    local doc,why=require('bmux.capture').collect(control,cache)
    if not doc then return response(nil,{status=503,message=why.message})end
    local text;text,why=require('bmux.checkpoint').encode(doc)
    if not text then return response(nil,{status=503,message=why.message})end
    return 200,text,{content_type='application/json'}
  end,'export bounded layout, cwd and plain history without execution credentials')
  control.route('POST','/layout/checkpoints/([%w_-]+)/([%w_-]+)',function(req,host_id,name)
    if req.query and req.query~=''then return response(nil,{status=400,message='checkpoint query parameters unsupported'})end
    if not control.layout then return response(nil,{status=503,message='layout host unavailable'})end
    if host_id~=control.layout.host_id then return response(nil,{status=409,message='Layout server changed; join it again explicitly'})end
    if #name>128 then return response(nil,{status=400,message='Import name exceeds 128 bytes'})end
    return response(require('bmux.journal').import(name,req.body or ''))
  end,'create a new inactive named checkpoint; existing sessions are never overwritten')
  control.route('GET','/layout/checkpoints/([%w_-]+)/([%w_-]+)',function(req,host_id,name)
    if req.query and req.query~=''then return response(nil,{status=400,message='checkpoint query parameters unsupported'})end
    if not control.layout then return response(nil,{status=503,message='layout host unavailable'})end
    if host_id~=control.layout.host_id then return response(nil,{status=409,message='Layout server changed; join it again explicitly'})end
    if #name>128 then return response(nil,{status=400,message='Import name exceeds 128 bytes'})end
    local raw,why=bog.store.kv_get('bmux.session.v1:'..name)
    if why then return response(nil,{status=503,message=tostring(why):sub(1,512)})end
    if not raw then return response(nil,{status=404,message='Saved session does not exist'})end
    local codec=require 'bmux.checkpoint'
    local doc;doc,why=codec.decode(raw)
    if not doc then return response(nil,{status=409,message=why.message})end
    local text;text,why=codec.encode(doc)
    if not text then return response(nil,{status=409,message=why.message})end
    return 200,text,{content_type='application/json'}
  end,'read a named checkpoint to inspect an uncertain import without replaying it')
  control.route('GET','/layout/session',function(req)
    if req.query and req.query~=''then return response(nil,{status=400,message='session query parameters unsupported'})end
    if not control.layout then return response(nil,{status=503,message='layout host unavailable'})end
    return response(session_status())
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
    if control.journal and control.journal.recovering then return response(nil,{status=409,message='Layout edits are paused during checkpoint recovery'})end
    local text=req.body or ''
    if #text>8192 or not text:match('^%s*{') then return response(nil,{status=400,message='layout command object required'}) end
    local parsed,body=pcall(json.decode,text)
    if not parsed then return response(nil,{status=400,message='invalid layout command JSON'}) end
    return response(host:command(body))
  end,'apply a validated layout command against an exact host identity and revision')
end
return M
