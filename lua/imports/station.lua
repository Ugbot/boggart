-- Explicit Station forge exports are unverified observations, not authority.
local json=require('json')
local hash=require('workflow').hash
local M={version=1}
local required_gaps={'policy','usage','verifier','context_resolution','code_revision','redaction'}
local function container(v)
  assert(type(v)=='table' and v~=json.null and getmetatable(v)==nil,'station_object')
  return v
end
local function object(v)
  container(v);for k in pairs(v) do assert(type(k)=='string','station_object_key') end
  return v
end
local function array(v)
  container(v)
  local n=0
  for k in pairs(v) do
    assert(type(k)=='number' and k%1==0 and k>=1 and k<=#v,'station_array');n=n+1
  end
  assert(n==#v and n<=2000,'station_array_limit');return v
end
local function text(v) assert(type(v)=='string' and v~='','station_text');return v end
local function redaction(v) assert(v==nil or type(v)=='boolean','station_redaction_flag');return v end
local function order(v) assert(type(v)=='number' and v>=0 and v%1==0,'station_step_order');return v end
local function pointer(k) return tostring(k):gsub('~','~0'):gsub('/','~1') end
local function observed(value)
  local nulls,empty={},{}
  local function copy(v,path)
    if v==json.null then nulls[#nulls+1]=path;return {import_value_type='json_null'} end
    if type(v)~='table' then return v end
    container(v)
    if next(v)==nil then empty[#empty+1]=path end
    local out={}
    for k,x in pairs(v) do out[k]=copy(x,path..'/'..pointer(type(k)=='number' and k-1 or k)) end
    return out
  end
  local result=copy(value,'')
  table.sort(nulls);table.sort(empty)
  return result,{kind='station_json',original_bytes_preserved=false,null_paths=nulls,
    ambiguous_empty_container_paths=empty}
end
local function gaps(payload)
  local out,seen={},{}
  for _,name in ipairs(required_gaps) do out[#out+1]=name;seen[name]=true end
  for _,name in ipairs(array(payload.missing_information or {})) do
    text(name);if not seen[name] then out[#out+1]=name;seen[name]=true end
  end
  return out
end
local function call_id(trace_id,step,tool)
  return 'station:'..hash(json.encode({trace_id,step,tool}))
end
function M.normalize(record)
  if record.schema~='station.forge' or record.schema_version~=1 then
    return {},nil,'unsupported_station_schema'
  end
  local p=object(record.payload)
  if record.kind=='ActionTemplate' then
    local id,version=text(p.template_id),text(p.version)
    array(p.params);array(p.steps)
    local seen={}
    for _,step in ipairs(p.steps) do
      object(step);local n=order(step.order);assert(not seen[n],'station_duplicate_step');seen[n]=true
      text(step.tool_name);object(step.fixed_args);object(step.template_args)
      object(step.argument_types);object(step.result_args)
    end
    local value,representation=observed(p)
    return {{kind='historical.station.template',value=value,representation=representation,
      identity_key='template:'..hash(json.encode({id,version})),activation_eligible=false,
      timestamp=p.updated_at or p.created_at,
      source_observation={schema=record.schema,schema_version=1,template_id=id,version=version,
        missing_information=gaps(p)}}},'station-template:'..id
  end
  if record.kind~='ActionTrace' then return {},nil,'unsupported_station_kind' end
  local id=text(p.trace_id)
  local session=p.session_id
  if session~=nil and session~='' then text(session) else session='station-trace:'..id end
  local calls,results=array(p.tool_calls),array(p.results)
  local call_orders,result_orders={},{}
  local uncorrelated=0
  for _,call in ipairs(calls) do
    object(call);local n=order(call.step_order);assert(not call_orders[n],'station_duplicate_step')
    call_orders[n]=text(call.tool);object(call.params);object(call.result_args or {});redaction(call.evidence_redacted)
  end
  for _,result in ipairs(results) do
    object(result);local n=result.step_order
    text(result.tool)
    if n==-1 then uncorrelated=uncorrelated+1
    else
      order(n);assert(not result_orders[n],'station_duplicate_result');result_orders[n]=result.tool
    end
    assert(type(result.success)=='boolean','station_result_success');redaction(result.evidence_redacted)
    assert(result.output_state=='available' or result.output_state=='truncated'
      or result.output_state=='unavailable' or result.output_state=='redacted','station_output_state')
    array(result.artifact_refs or {})
    if result.output_state=='available' or result.output_state=='redacted' then assert(result.output~=nil,'station_output_missing') end
  end
  local header={}
  for k,v in pairs(p) do if k~='tool_calls' and k~='results' then header[k]=v end end
  local value,representation=observed(header)
  local missing,orphan=0,uncorrelated
  for n,name in pairs(call_orders) do if result_orders[n]~=name then missing=missing+1 end end
  for n,name in pairs(result_orders) do if call_orders[n]~=name then orphan=orphan+1 end end
  local out={{kind='historical.station.trace',value=value,representation=representation,
    identity_key='trace:'..hash(id),timestamp=p.captured_at,activation_eligible=false,
    source_observation={schema=record.schema,schema_version=1,trace_id=id,
      missing_information=gaps(p),missing_results=missing,orphan_results=orphan}}}
  for _,call in ipairs(calls) do
    local cid=call_id(id,call.step_order,call.tool)
    local args,repr=observed(call.params)
    out[#out+1]={kind='tool.request',name=call.tool,value=args,representation=repr,
      value_provenance=call.evidence_redacted and 'redacted' or nil,
      coverage_reason=call.evidence_redacted and 'station_source_redacted' or nil,
      identity_key=cid,call_id=cid,call_id_provenance='inferred',
      source_observation={trace_id=id,step_order=call.step_order,evidence_redacted=call.evidence_redacted,
        step_order_provenance=call.step_order_provenance,
        result_args=observed(call.result_args or {}),
        correlation='trace_step_tool',timestamp='missing'}}
  end
  for index,result in ipairs(results) do
    local correlated=result.step_order>=0
    local cid=correlated and call_id(id,result.step_order,result.tool) or nil
    local identity=cid or 'station-orphan:'..hash(json.encode({id,index,result.tool}))
    local output,repr
    if result.output_state~='unavailable' then output,repr=observed(result.output) end
    local partial=result.output_state=='truncated'
    local redacted=result.output_state=='redacted' or result.evidence_redacted
    out[#out+1]={kind='tool.result',name=result.tool,value=output,representation=repr,
      identity_key=identity,call_id=cid,call_id_provenance=cid and 'inferred' or nil,reported_error=not result.success,
      value_provenance=partial and 'partial' or (redacted and output~=nil and 'redacted' or nil),
      coverage_reason=partial and 'station_output_truncated' or (redacted and 'station_source_redacted' or nil),
      source_observation={trace_id=id,step_order=result.step_order,output_state=result.output_state,
        evidence_redacted=result.evidence_redacted,step_order_provenance=result.step_order_provenance,
        output_length=result.output_length,
        artifact_refs=observed(result.artifact_refs or {}),original_bytes=result.original_bytes,
        request_observed=correlated and call_orders[result.step_order]==result.tool or false,
        correlation=correlated and 'trace_step_tool' or 'unavailable',timestamp='missing'}}
  end
  return out,session
end
return M
