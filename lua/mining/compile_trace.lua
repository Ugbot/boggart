-- Internal source-free lowering for mining.compile. The public compiler bounds
-- input first and validates shared alignment, descriptor and activation contracts.
-- Observed argument/result values are inspected only to validate explicit links;
-- they never supply generated literals or inferred control decisions.
local M={}
local function fail(code)error({code=code},0)end
local function identity(s)return type(s)=='string' and #s>0 and #s<=128 and s:match('^[%a_][%w_.-]*$')end
local function path(value,input)
 if type(value)~='string' or #value>256 then fail('unsupported_binding_pointer') end
 if value=='' or value=='/' then return {} end
 if value:sub(1,1)=='/' then value=value:sub(2) end
 value=value:gsub('%.','/')
 local parts={}
 for part in value:gmatch('[^/]+')do
  if not part:match('^[%a_][%w_]*$') then fail('unsupported_binding_pointer') end
  parts[#parts+1]=part
 end
 if table.concat(parts,'/')~=value or #parts>16 or input and #parts>1 then fail('unsupported_binding_pointer') end
 return parts
end
local function available(value)
 if type(value)=='table' then
  if value.evidence_marker then return false end
  for k,v in pairs(value)do if not available(k) or not available(v) then return false end end
 elseif type(value)=='string' then return not value:find('[REDACTED]',1,true)
 elseif type(value)=='number' then return value==value and math.abs(value)<math.huge end
 return value~=nil
end
local function lookup(value,parts)
 for _,part in ipairs(parts)do
  if type(value)~='table' or value.evidence_marker then fail('binding_value_unavailable') end
  value=value[part]
 end
 if not available(value) then fail('binding_value_unavailable') end
 return value
end
local function same(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for key,value in pairs(a)do if not same(value,b[key]) then return false end end
 for key in pairs(b)do if a[key]==nil then return false end end
 return true
end
local function evidence_index(trace)
 local result={}
 for _,entry in ipairs(trace.evidence or {})do
  if entry.event_id then
   if result[entry.event_id] then fail('incomplete_evidence') end
   result[entry.event_id]=entry
  end
 end
 return result
end
function M.lower(alignment,options,ti)
 if options.parameters or options.call_sites then fail('source_evidence_required') end
 if alignment.variants[ti].ast then fail('source_evidence_required') end
 local trace=alignment.traces[ti]
 if type(trace.steps)~='table' or #trace.steps<1 or #trace.steps>128 then fail('source_correspondence_required') end
 if #(trace.branches or {})>0 then fail('trace_control_flow_unsupported') end
 local evidence=evidence_index(trace)
 local calls,required,maps,bindings,unknowns={},{},{},{},{}
 local ids,sites={},{}
 for _,step in ipairs(trace.step_occurrences or {})do
  local site=step.payload and step.payload.site
  if not identity(site) or sites[site] then fail('trace_control_flow_unsupported') end
  sites[site]=true
 end
 local previous_end=0
 for i,step in ipairs(trace.steps)do
  local descriptor=step.descriptor
  if step.origin~='native' or step.status~='succeeded' or not descriptor or
   not identity(descriptor.id) or type(descriptor.version)~='string' or #descriptor.version==0 or #descriptor.version>128 or not identity(descriptor.target) or
   not ({pure=true,read=true,write=true})[descriptor.effect] then fail('capability_evidence_required') end
  if not step.id or ids[step.id] then fail('ambiguous_alignment') end;ids[step.id]=true
  if type(step.start_position)~='number' or type(step.terminal_position)~='number' or
   step.start_position%1~=0 or step.terminal_position%1~=0 or step.start_position<=previous_end or step.terminal_position<=step.start_position then fail('trace_control_flow_unsupported') end
  previous_end=step.terminal_position
  for _,ref in ipairs({step.event_id,step.output_event_id})do
   if not evidence[ref] or evidence[ref].origin~='native' then fail('source_correspondence_required') end
  end
  if not step.event_id or not step.output_event_id then fail('source_correspondence_required') end
  if type(step.input)~='table' or step.input.evidence_marker then fail('trace_arguments_unavailable') end
  calls[i]={name=descriptor.id,descriptor=descriptor,occurrence=i,evidence={step.event_id,step.output_event_id}}
 end
 -- Any claimed binding must be present and compatible on every selected trace.
 -- Fully unbound calls are independent injected inputs, never guessed links.
 for vi=2,#alignment.traces do
  local relation=alignment.variants[vi].relationships
  if not relation or not relation.bindings then fail('binding_evidence_required') end
  for _,comparison in ipairs(relation.bindings.comparisons or {})do
   if comparison.status~='compatible' then fail('binding_evidence_required') end
  end
 end
 local by_consumer={}
 if #(alignment.bindings[ti] or {})>128 then fail('resource_limit') end
 for _,binding in ipairs(alignment.bindings[ti] or {})do
  local producer,consumer=binding.producer,binding.consumer
  if type(producer)~='number' or producer%1~=0 or type(consumer)~='number' or consumer%1~=0 or
   producer<1 or producer>=consumer or consumer>#calls or binding.provenance~='explicit_annotation' or
   not evidence[binding.evidence] or evidence[binding.evidence].origin~='native' then fail('binding_evidence_required') end
  local output,input=path(binding.output,false),path(binding.input,true)
  if not same(lookup(trace.steps[producer].output,output),lookup(trace.steps[consumer].input,input)) then fail('binding_value_mismatch') end
  local key=table.concat(input,'/')
  by_consumer[consumer]=by_consumer[consumer] or {}
  if by_consumer[consumer][key] then fail('binding_evidence_required') end
  by_consumer[consumer][key]={producer=producer,consumer=consumer,input=key,output=table.concat(output,'/'),parts=output,
   evidence=binding.evidence,kind='explicit_observation_validated',synthesized=true}
 end
 local lines={[[return {run=function(ctx)
local function _compiled_args(value)
 assert(type(value)=="table", "compiled_arguments_required")
 local result, count = {}, 0
 for key, item in pairs(value) do
  count=count+1
  if count>1024 then error("compiled_arguments_limit") end
  result[key]=item
 end
 return result
end
local function _compiled_bound(value, path, whole_input)
 for _, field in ipairs(path) do
  assert(type(value)=="table", "compiled_binding_container_required")
  value=value[field]
 end
 assert(value~=nil, "compiled_binding_value_required")
 if whole_input then assert(type(value)=="table", "compiled_arguments_required") end
 return value
end]]}
 local function emit(value)lines[#lines+1]=value end
 local function output_expression(binding)
  local parts={}
  for _,part in ipairs(binding.parts)do parts[#parts+1]=string.format('%q',part) end
  return '_compiled_bound(_compiled_outcome_'..binding.producer..'.result, {'..table.concat(parts,', ')..'}, '..tostring(binding.input=='')..')'
 end
 for i,call in ipairs(calls)do
  local linked=by_consumer[i] or {};local keys={}
  for key in pairs(linked)do keys[#keys+1]=key end;table.sort(keys)
  if linked[''] and #keys~=1 then fail('binding_evidence_required') end
  -- Validate fresh producer paths before resolving potentially effectful current
  -- consumer arguments. False/zero leaves survive; only path shape is guarded.
  local resolved={}
  for ordinal,key in ipairs(keys)do
   resolved[key]='_compiled_bound_'..i..'_'..ordinal
   emit('local '..resolved[key]..' = '..output_expression(linked[key]))
  end
  if linked[''] then emit('local _compiled_input_'..i..' = '..resolved[''])
  else
   local key='call_'..i..'_args'
   required[#required+1]={key=key,required=true,origin='synthesized_current_arguments',occurrence=i,evidence=call.evidence}
   emit('local _compiled_input_'..i..' = _compiled_args(ctx:resolve('..string.format('%q',key)..'))')
  end
  for _,key in ipairs(keys)do
   local binding=linked[key]
   if key~='' then emit('_compiled_input_'..i..'['..string.format('%q',key)..'] = '..resolved[key]) end
   bindings[#bindings+1]={producer=binding.producer,consumer=i,input=binding.input,output=binding.output,evidence=binding.evidence,kind=binding.kind,synthesized=true}
  end
  if #keys==0 and i>1 then unknowns[#unknowns+1]={code='input_lineage_unobserved',occurrence=i,resolution='current_injected_arguments'} end
  local site='observed_call_'..i
  maps[#maps+1]={site=site,kind=options.residual_capabilities and options.residual_capabilities[call.name] and 'residual_model' or 'capability',
   occurrence=i,synthesized=true,evidence=call.evidence,generated_line=#lines+1}
  emit('local _compiled_outcome_'..i..' = ctx:step('..string.format('%q',site)..', function()')
  emit(' local outcome = ctx:call('..string.format('%q',call.name)..', _compiled_input_'..i..')')
  emit(' if outcome.status ~= "succeeded" then error("compiled_call_failed") end')
  emit(' return outcome\nend)')
 end
 emit('return _compiled_outcome_'..#calls..'.result\nend}\n')
 local source=table.concat(lines,'\n')
 if #source>262144 then fail('resource_limit') end
 for _,map in ipairs(maps)do
  local position=assert(source:find(string.format('%q',map.site),1,true))
  local _,count=source:sub(1,position):gsub('\n','');map.generated_line=count+1
 end
 unknowns[#unknowns+1]={code='surrounding_control_flow_unobserved'}
 unknowns[#unknowns+1]={code='current_argument_bindings_synthesized'}
 unknowns[#unknowns+1]={code='last_invocation_result_synthesized',occurrence=#calls}
 return {source=source,required=required,maps=maps,calls=calls,bindings=bindings,unknowns=unknowns,index={},loops=0,mode='trace-sequence-v1'}
end
return M
