-- Test-only control overlay. Times real code without replacing admission.
local uv=require 'uv';local scope;local serial=0
local function emit(stage,milliseconds)
  io.stderr:write(string.format('BMUX_PROBE %d %s %s %.3fms\n',scope.serial,scope.kind,stage,milliseconds))
end
local function measured(owner,name,label)
  local original=owner[name]
  owner[name]=function(...)
    if not scope then return original(...)end
    local started=uv.hrtime();local values=table.pack(original(...))
    emit(label,(uv.hrtime()-started)/1e6);return table.unpack(values,1,values.n)
  end
end
measured(require 'invoke','call','invoke')
local evidence=require 'evidence'
for _,name in ipairs{'begin','append','finish'}do measured(evidence,name,'evidence.'..name)end
local registry=require 'terminal.registry';local make=registry.new
registry.new=function(...)
  local host=make(...);measured(host.attachments,'capture','capture');return host
end
local listen=serve.listen
serve.listen=function(opts)
  local handler=opts.handler
  opts.handler=function(req)
    local category=req.path:match('/attachments$') and 'attach' or req.path:match('/stream$') and 'stream'
    if category then serial=serial+1;scope={serial=serial,kind=category}end
    local started=uv.hrtime();local values=table.pack(handler(req))
    if category then emit('handler',(uv.hrtime()-started)/1e6)end
    scope=nil;return table.unpack(values,1,values.n)
  end
  return listen(opts)
end
return dofile('lua/control.lua')
