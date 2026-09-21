-- Trusted host boundary: Lua keeps control flow; AIbyWire owns delegated retries.
local M={}
local json,cap,evidence=require('json'),require('capability'),require('evidence')
local CONTRACT,BACKEND='boggart-durable-v1','python-native-sqlite'
local function copy(v)
  if type(v)~='table' then return v end
  local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function failure(code,message,uncertain)
  return nil,{status=uncertain and 'uncertain' or 'failed',effect_disproven=not uncertain,
    error={code=code,message=message or code,retryable=false}}
end
local function decode(raw)
  if type(raw)~='string' then return nil end
  local ok,value=pcall(json.decode,raw)
  if ok and type(value)=='table' and value~=json.null then return value end
end
local function response(raw)
  local envelope=decode(raw)
  if not envelope or envelope.isError or type(envelope.content)~='table' or #envelope.content~=1 then return nil end
  for key in pairs(envelope.content) do if key~=1 then return nil end end
  local block=envelope.content[1]
  if type(block)~='table' or block.type~='text' then return nil end
  return decode(block.text),block.text
end
-- Preserve schema-directed empty arrays at the wire boundary. The replay input
-- remains ordinary Lua data, without metatable sentinels or arbitrary closures.
local function wire(value,schema,depth)
  depth=(depth or 0)+1;assert(depth<=32,'nested input too deep')
  local kind=type(value)
  if kind=='number' then
    assert(value==value and math.abs(value)<=999999999999999,'number outside qualified MCP range')
    assert(tonumber(string.format('%.14g',value))==value or math.type(value)=='integer','decimal loses precision in JSON')
  elseif kind=='table' then
    assert(not getmetatable(value),'sentinels/metatables are not replay inputs')
    local out,n={},0
    for k,v in pairs(value) do
      n=n+1;assert(n<=20000,'input too large')
      assert(type(k)=='string' or type(k)=='number' and k>=1 and k%1==0,'invalid JSON key')
      out[k]=wire(v,schema and (schema.type=='array' and schema.items or schema.properties and schema.properties[k]),depth)
    end
    if schema and schema.type=='array' then
      for k in pairs(out) do assert(type(k)=='number' and k<=n,'invalid JSON array') end
      return n==0 and json.array or out
    end
    if n>0 then
      local array=type(next(out))=='number'
      for k in pairs(out) do assert(array and type(k)=='number' and k<=n or not array and type(k)=='string','mixed or sparse table') end
    end
    return out
  else assert(kind=='string' or kind=='boolean' or kind=='nil','unsupported JSON value') end
  return value
end
local function remote_id(operation)
  assert(type(operation)=='string' and #operation>0 and #operation<=240 and operation:match('^[%w_.:-]+$'),'invalid durable operation identity')
  return 'boggart:'..operation
end
local function valid_receipt(r,operation)
  if type(r)~='table' or r.backend~=BACKEND or r.remote_run_id~=remote_id(operation)
    or r.operation_id~=operation or not ({running=true,succeeded=true,failed=true,cancelled=true,uncertain=true})[r.state]
    or r.retry_owner~='aibywire' or r.policy_ack~=false or r.usage_ack~=false or type(r.artifacts)~='table' then return false end
  -- Artifacts are currently unqualified; do not silently accept arbitrary data
  -- in a field advertised as an array, or numeric results the wire cannot keep.
  if next(r.artifacts)~=nil then return false end
  if r.state=='succeeded' and r.result==nil then return false end
  if r.result~=nil and r.result~=json.null and not pcall(wire,r.result) then return false end
  return true
end
-- Inspect the entire parsed response before retaining opaque bytes. Structured
-- redaction learns secrets under sensitive keys even outside delegation, and
-- decodes escaped secret values before comparing them. Null sentinels carry no
-- private data and are normalized solely for this comparison.
local function private_receipt(reply,source_json,operation)
  local projected=copy(reply)
  local clean=evidence.redact(projected)
  local changed=json.encode(clean)~=json.encode(projected)
  if not valid_receipt(clean.delegation,operation) then return nil end
  local receipt=copy(clean.delegation)
  receipt.result_representation={format='lua-json-projection',empty_container_kind='unavailable',
    exact_source=changed and 'unavailable' or 'response_json',source_status=changed and 'redacted' or 'exact'}
  if not changed then receipt.response_json=source_json end
  if reply.delegation.result==json.null then receipt.result=nil end
  return receipt
end
function M.new(options)
  options=options or {}
  local conn=assert(options.mcp,'an attached MCP connection is required')
  local target=assert(options.target or options.id,'host endpoint identity required')
  local catalog,qualified,registered={},false,{}
  local self={}
  local function database()
    local db=assert(options.db or (bog and bog.db),'durable database required')
    assert(db:exec([[CREATE TABLE IF NOT EXISTS aibywire_operations (
      target TEXT NOT NULL, operation_id TEXT NOT NULL, remote_run_id TEXT NOT NULL,
      request_hash TEXT NOT NULL, run_id TEXT NOT NULL,
      PRIMARY KEY(target,operation_id));]]),'durable database unavailable')
    return db
  end
  local function request_hash(id,version,args)
    local _,body=require('runstore').snapshot({capability=id,version=version,args=args})
    return require('workflow').hash(body)
  end
  local function lookup(operation,id,version,args)
    local row=assert(database():query('SELECT remote_run_id,request_hash,run_id FROM aibywire_operations WHERE target=? AND operation_id=?',{target,operation}))[1]
    assert(row and row.remote_run_id==remote_id(operation) and row.request_hash==request_hash(id,version,args),'operation identity conflict or unavailable')
    evidence.assert_run(row.run_id)
    return row
  end
  local discovery_id='aibywire.discovery.'..target
  local function rpc(command,args)
    local encoded=json.encode(args or {})
    local ok,raw=pcall(function()return conn:call(command,encoded)end)
    if ok then return response(raw) end
    return nil
  end
  assert(cap.register({id=discovery_id,version='1',effect='read',target='aibywire:'..target,input_schema={type='object'}},function()
    local cursor,seen,available=nil,{},{}
    for page=1,100 do
      local ok,raw=pcall(function()return conn:list_tools(cursor)end)
      local list=ok and decode(raw)
      if not list or type(list.tools)~='table' then return failure('invalid_discovery') end
      for _,tool in ipairs(list.tools) do
        if type(tool.name)~='string' or type(tool.inputSchema)~='table' then return failure('invalid_discovery') end
        available[tool.name]=true
      end
      cursor=list.nextCursor
      if cursor==nil or cursor=='' then break end
      if type(cursor)~='string' or seen[cursor] or page==100 then return failure('invalid_discovery') end
      seen[cursor]=true
    end
    for _,name in ipairs({'list_tools','submit_workflow_dag','get_dag','get_dag_status','cancel_dag'}) do
      if not available[name] then return failure('unsupported_backend','MCP profile does not expose '..name) end
    end
    local found=rpc('list_tools',{})
    local f=found and found.delegation
    if not found or found.status~='OK' or type(found.data)~='table' or type(f)~='table'
      or f.contract~=CONTRACT or f.backend~=BACKEND or f.atomic_submit~=true or f.retry_owner~='aibywire'
      or f.policy_ack~=false or f.usage_ack~=false then return failure('unsupported_backend') end
    local next_catalog={}
    for _,tool in ipairs(found.data) do
      if type(tool.tool_id)~='string' or type(tool.input_schema)~='table' or next_catalog[tool.tool_id] then return failure('invalid_discovery') end
      next_catalog[tool.tool_id]=copy(tool)
    end
    catalog,qualified=next_catalog,true
    return copy(found),{status='succeeded'}
  end))
  function self:discover(context)
    qualified=false
    local out=cap.call(context,discovery_id,'1',{})
    if out.status~='succeeded' then return nil,out.error end
    return out.result
  end
  local function observe(args,execution,command,id,version)
    local operation=execution.operation_id
    if not pcall(lookup,operation,id,version,args) then return failure('operation_identity_unavailable') end
    local reply,source_json=rpc(command,{dag_id=remote_id(operation),compensate=command=='cancel_dag' and false or nil})
    if not reply or reply.status~='OK' or not valid_receipt(reply.delegation,operation) then return failure('remote_observation_uncertain',nil,true) end
    local safe,receipt=pcall(private_receipt,reply,source_json,operation)
    if not safe or not receipt then return failure('receipt_redaction_unavailable',nil,true) end
    return receipt,{status='succeeded',receipt=copy(receipt)}
  end
  function self:register_dag(host)
    if not qualified then return nil,'qualified discovery required' end
    if type(host)~='table' or type(host.build)~='function' or type(host.version)~='string' or type(host.id)~='string' then return nil,'host id/version/build required' end
    if host.bounded then return nil,'remote usage ceilings are unqualified' end
    local h=copy(host)
    local descriptor={id=h.id,version=h.version,effect=h.effect or 'unknown',target='aibywire:'..target,
      resources=h.resources,requires_approval=h.requires_approval,input_schema=h.input_schema or {type='object'},
      output_schema={type='object'},reconcile=function(args,execution)return observe(args,execution,'get_dag',h.id,h.version)end,
      aibywire={contract=CONTRACT,backend=BACKEND,retry_owner='aibywire',policy_ack=false,usage_ack=false}}
    local function submit(args,execution)
      local ok,definition=pcall(function()
        local d=copy(h.build(copy(args)))
        assert(type(d)=='table' and type(d.nodes)=='table' and #d.nodes>0 and #d.nodes<=128,'bounded static nodes required')
        d.dag_id=remote_id(execution.operation_id)
        d.context=d.context or {};d.context.boggart_delegation=CONTRACT;d.context.operation_id=execution.operation_id
        d.patch_policy='Frozen'
        for _,node in ipairs(d.nodes) do
          local tool=catalog[node.task_name];assert(tool,'undiscovered worker tool')
          assert(not tool.requires_approval,'remote approval profile unqualified')
          node.inputs=wire(node.inputs or {},tool.input_schema)
          if node.depends_on and next(node.depends_on)==nil then node.depends_on=nil end
        end
        -- Convert before encode, but persist only sentinel-free replay input.
        return d
      end)
      if not ok then return failure('unsupported_encoding',tostring(definition)) end
      local checked,encoded=pcall(function()
        -- Check all scalar values, including host-built metadata. Empty input
        -- arrays are encoded in the preceding schema-directed pass.
        local function scalar(v)
          if v==json.array then return end
          if type(v)=='table' then for k,x in pairs(v) do assert(type(k)=='string' or type(k)=='number');scalar(x) end
          else wire(v) end
        end
        scalar(definition)
        return json.encode({definition=definition,backend='native'})
      end)
      if not checked or #encoded>1048576 then return failure('unsupported_encoding',tostring(encoded)) end
      local identity={operation_id=execution.operation_id,remote_run_id=definition.dag_id,backend=BACKEND,capability=h.id,version=h.version,target=target}
      local safe=pcall(require('runstore').snapshot,identity)
      if not safe then return failure('checkpoint_unavailable') end
      local correlation=require('invoke').correlation()
      local stored=pcall(function()
        local db=database()
        local hash=request_hash(h.id,h.version,args)
        assert(db:run('INSERT OR IGNORE INTO aibywire_operations(target,operation_id,remote_run_id,request_hash,run_id) VALUES(?,?,?,?,?)',
          {target,execution.operation_id,definition.dag_id,hash,assert(correlation.run_id)}))
        lookup(execution.operation_id,h.id,h.version,args)
      end)
      if not stored then return failure('operation_identity_unavailable') end
      correlation.kind='aibywire.delegation';correlation.payload=identity
      if not evidence.append(correlation) then return failure('checkpoint_unavailable') end
      local sent,raw=pcall(function()return conn:call('submit_workflow_dag',encoded)end)
      local reply,source_json
      if sent then reply,source_json=response(raw) end
      if not reply or reply.status~='OK' or not valid_receipt(reply.delegation,execution.operation_id) then
        return failure('submission_uncertain',nil,true)
      end
      local safe,receipt=pcall(private_receipt,reply,source_json,execution.operation_id)
      if not safe or not receipt then return failure('receipt_redaction_unavailable',nil,true) end
      return receipt,{status='succeeded',receipt=copy(receipt)}
    end
    if cap.resolve(h.id,h.version) or cap.resolve(h.id..'.cancel',h.version) then return nil,'capability version already registered' end
    local d,err=cap.register(descriptor,submit)
    if not d then return nil,err end
    local cancel=copy(descriptor);cancel.id=h.id..'.cancel';cancel.effect='write';cancel.reconcile=nil
    local c,ce=cap.register(cancel,function(args,execution)return observe(args,execution,'cancel_dag',h.id,h.version)end)
    if not c then return nil,ce end
    registered[h.id..'@'..h.version]=true
    return d
  end
  function self:register(tool_name,host)
    local tool=catalog[tool_name];if not tool then return nil,'discover worker tool first' end
    local h=copy(host or {});h.input_schema=copy(tool.input_schema)
    h.requires_approval=h.requires_approval or tool.requires_approval
    h.build=function(args)return {nodes={{node_id='job',task_name=tool_name,inputs=args,retry_policy=copy(h.retry_policy or {max_attempts=1})}}}end
    return self:register_dag(h)
  end
  local function known(id,version)
    return registered[tostring(id)..'@'..tostring(version)]
  end
  function self:submit(context,id,version,args,opts)
    if not known(id,version) then return {status='failed',error={code='version_unavailable'}} end
    return cap.call(context,id,version,args,opts)
  end
  self.invoke=self.submit
  function self:reconnect(context,id,version,args,operation)
    if not known(id,version) then return {status='failed',error={code='version_unavailable'}} end
    if not pcall(remote_id,operation) then return {status='failed',error={code='invalid_operation_id'}} end
    return cap.reconcile(context,id,version,args,operation)
  end
  self.status=self.reconnect
  function self:cancel(context,id,version,args,operation)
    if not known(id,version) then return {status='failed',error={code='version_unavailable'}} end
    if not pcall(remote_id,operation) then return {status='failed',error={code='invalid_operation_id'}} end
    return cap.call(context,id..'.cancel',version,args,{operation_id=operation})
  end
  return self
end
return M
