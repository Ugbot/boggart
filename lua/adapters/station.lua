-- Trusted host adapter. Discovery describes remote schemas; only the host can
-- qualify effects, resources and local version identities. No remote policy claim.
local M = {}
local json, capability = require("json"), require("capability")
local function copy(x)
  if type(x) ~= "table" then return x end
  local r={}; for k,v in pairs(x) do r[k]=copy(v) end; return r
end
local function unsupported(operation)
  return {status="failed",error={code="unsupported",message=operation.." is not supported by the Station tool protocol",retryable=false}}
end
local function decode(raw)
  local ok,value=pcall(json.decode,raw or "")
  if ok and type(value)=="table" then return value end
  return nil,"invalid Station JSON response"
end
-- json.decode erases the empty array/object distinction. Station always
-- returns a text block (even for empty text), so require a nonempty dense array.
local function content_text(content)
  if content == json.null then return nil,"null" end
  if type(content) ~= "table" then return nil,"missing_or_nonarray" end
  local n=0
  for k in pairs(content) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return nil,"nonarray_keys" end
    n=n+1
  end
  if n==0 then return nil,"empty_array_or_object" end
  local parts={}
  for i=1,n do
    local block=content[i]
    if block==nil then return nil,"sparse_array" end
    if type(block) ~= "table" or block == json.null or block.type ~= "text" or type(block.text) ~= "string" then return nil,"invalid_block" end
    parts[i]=block.text
  end
  return table.concat(parts,"\n"),"text_array"
end
local function text_schema(raw,name)
  if raw:match("^Tool: ([^\n]+)")~=name then return nil,"schema tool mismatch" end
  local body=raw:match("\nParameters:\n(.*)")
  if not body then return nil,"missing Parameters section" end
  local schema={type="object",properties={},required={}}
  for line in body:gmatch("[^\n]+") do
    local key,kind,tail=line:match("^  ([%w_%-]+) %(([%w_]+)%)%s*(.*)$")
    if not key then return nil,"unrecognized schema parameter" end
    schema.properties[key]={type=kind}
    if tail:match("^%[required%]") then schema.required[#schema.required+1]=key end
  end
  return schema
end
function M.new(options)
  options=options or {}
  local link=options.link or require("stationlink")
  local transport=os.getenv("BOGGART_STATION_FORCE_MCP")=="1" and "mcp" or "zmq"
  local workspace=options.workspace
  local remote,registered={},{}
  local function mcp_conn()
    return options.mcp or (bog.mcphost and bog.mcphost.conns[require("llmstation").SERVER])
  end
  local self={}
  function self:features()
    local info={transport=transport,encoding="flat-string-integer-15digits",cancel=false,status=false,
      reconcile=false,remote_policy=false,remote_correlation=false,capability_version=false,
      protocol=false,version_negotiation=false}
    if transport=="mcp" then
      local c=mcp_conn()
      if c and c.info then
        local ok,raw=pcall(function() return c:info() end)
        local negotiated=ok and decode(raw)
        if negotiated then info.protocol=negotiated.protocol or false end
      end
    end
    return info
  end
  function self:discover()
    local found={}
    if transport=="zmq" then
      local data,meta=link.request(nil,{}, {msg_type="list_tools",workspace=workspace})
      if not data then return nil,meta.error end
      for line in data:gmatch("[^\n]+") do
        local name,category,description=line:match("^([^\t]+)\t([^\t]*)\t(.*)$")
        if not name then return nil,{code="invalid_discovery",message="invalid tool list"} end
        local raw,sm=link.request(name,{}, {msg_type="tool_schema",workspace=workspace})
        if not raw then return nil,sm.error end
        local schema,err=text_schema(raw,name)
        if not schema then return nil,{code="invalid_schema",message=err} end
        found[#found+1]={name=name,description=description,category=category,input_schema=schema,raw_schema=raw}
      end
    else
      local c=mcp_conn(); if not c then return nil,{code="transport_unavailable",message="MCP is not attached"} end
      local cursor,seen=nil,{}
      for page=1,100 do
        local ok,raw,err=pcall(function() return c:list_tools(cursor) end)
        if not ok or not raw then return nil,{code="discovery_failed",message=tostring(ok and err or raw)} end
        local response,de=decode(raw); if not response or type(response.tools)~="table" then return nil,{code="invalid_discovery",message=de or "missing tools"} end
        for _,tool in ipairs(response.tools) do
          if type(tool.name)~="string" or type(tool.inputSchema)~="table" then return nil,{code="invalid_schema",message="missing name/schema"} end
          found[#found+1]={name=tool.name,description=tool.description,input_schema=copy(tool.inputSchema)}
        end
        cursor=response.nextCursor
        if cursor==nil or cursor=="" then break end
        if type(cursor)~="string" or seen[cursor] or page==100 then return nil,{code="invalid_discovery",message="pagination did not terminate"} end
        seen[cursor]=true
      end
    end
    local next_remote={}
    for _,d in ipairs(found) do
      if next_remote[d.name] then return nil,{code="invalid_discovery",message="duplicate tool"} end
      next_remote[d.name]=copy(d)
    end
    remote=next_remote
    return copy(found)
  end
  local function execute(name,args,execution)
    local correlation=require("invoke").correlation()
    local result,meta
    if transport=="zmq" then
      result,meta=link.request(name,args,{workspace=workspace,timeout_ms=options.timeout_ms})
    else
      local c=mcp_conn()
      if not c then meta={status="failed",effect_disproven=true,error={code="transport_unavailable",message="MCP is not attached"},receipt={dispatch="not_sent"}}
      else
        local routed=copy(args)
        if workspace then routed.workspace=tostring(workspace) end
        local encoded=json.encode(routed)
        local ok,raw,err=pcall(function() return c:call(name,encoded) end)
        local response=ok and raw and decode(raw)
        meta={status="uncertain",error={code="reply_unavailable",message=tostring(err or "invalid or missing MCP reply"),retryable=false},receipt={dispatch="unknown"}}
        if response then
          local text,shape=content_text(response.content)
          meta.receipt={dispatch="replied",remote=response.structuredContent,mcp_result=response,content_shape=shape}
          if response.isError then
            meta.error={code="remote_error",message=text or "Station MCP tool error with invalid content",retryable=false}
          elseif text~=nil then result=text;meta.status="succeeded";meta.error=nil
          else meta.error={code="invalid_response",message="Station MCP content must be a nonempty dense array of text blocks",retryable=false} end
        end
      end
    end
    meta.receipt=meta.receipt or {};meta.receipt.transport=transport
    meta.receipt.invocation_id=execution.invocation_id;meta.receipt.operation_id=execution.operation_id
    meta.receipt.run_id=correlation.run_id;meta.receipt.remote_policy=false
    meta.receipt.remote_correlation="unavailable"
    return result,meta
  end
  function self:register(name,host)
    local source=remote[name];if not source then return nil,"discover the tool first" end
    host=host or {}
    if not host.version then return nil,"host-qualified version required" end
    if host.bounded then return nil,"remote usage ceilings are unsupported" end
    local descriptor={id=host.id or "station."..name,version=host.version,effect=host.effect or "unknown",
      target="station:"..transport..":"..tostring(workspace or "default"),resources=host.resources,
      requires_approval=host.requires_approval,input_schema=copy(source.input_schema),output_schema={type="string"},
      station={tool=name,transport=transport,workspace=workspace,discovery=copy(source),features=self:features()}}
    local d,err=capability.register(descriptor,function(args,execution)
      -- Transport validation is also required for allowed additional properties.
      local valid,why=link.validate_params(args)
      if not valid then return nil,{status="failed",effect_disproven=true,error={code="unsupported_encoding",message=why},receipt={dispatch="not_sent"}} end
      return execute(name,args,execution)
    end)
    if d then registered[d.id.."@"..d.version]=true end
    return d,err
  end
  function self:invoke(context,id,version,args,opts)
    if not registered[tostring(id).."@"..tostring(version)] then return {status="failed",error={code="version_unavailable"}} end
    return capability.call(context,id,version,args,opts)
  end
  function self:cancel() return unsupported("cancellation") end
  function self:status() return unsupported("operation status") end
  function self:reconcile() return unsupported("reconciliation") end
  return self
end
return M
