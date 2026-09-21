-- Privileged analysis only: observed traces and re-parsed source produce an inactive
-- ordinary-Lua candidate. No source, provider, or capability is executed here.
local ast,workflow=require('mining.ast'),require('workflow')
local M={}
local function fail(code) error({code=code},0) end
local function identifier(s) return type(s)=='string' and #s>0 and #s<=128 and s:match('^[%a_][%w_.-]*$') end
local function bounded(value)
 local count,bytes,active=0,0,{}
 local function walk(v,depth)
  count=count+1;if count>200000 or depth>64 then fail('resource_limit') end
  local kind=type(v)
  if kind=='string' then bytes=bytes+#v;if #v>262144 or bytes>8388608 then fail('resource_limit') end
  elseif kind=='table' then
   if getmetatable(v) or active[v] then fail('invalid_input') end
   active[v]=true;for k,x in next,v do
    if type(k)~='string' and type(k)~='number' then fail('invalid_input') end
    walk(k,depth+1);walk(x,depth+1)
   end;active[v]=nil
  elseif kind~='nil' and kind~='boolean' and kind~='number' then fail('invalid_input') end
 end
 walk(value,0)
end
local function children(index,node,field,kind)
 local result={}
 for _,id in ipairs(node.children)do local c=index.nodes[id]
  if (not field or c.field==field) and (not kind or c.kind==kind) then result[#result+1]=c end
 end
 return result
end
local function child(index,node,field,kind)return children(index,node,field,kind)[1]end
local function named(index,node)
 local result={};for _,id in ipairs(node.children)do local c=index.nodes[id];if c.named then result[#result+1]=c end end;return result
end
local function literal(index,node)
 -- Deliberately no load() of evidence: only unescaped, short quoted strings.
 if not node or node.kind~='string' then return nil end
 local s=index.source:sub(node.span.start_byte,node.span.end_byte-1)
 local q=s:sub(1,1)
 if (q~="'" and q~='"') or s:sub(-1)~=q or s:find('\\',1,true) or s:find('[\r\n]') then return nil end
 return s:sub(2,-2)
end
local function union(a,b)for k in pairs(b or {})do a[k]=true end;return a end
local function pointer(path)
 if type(path)~='string' or #path>256 then return nil end
 if path=='' or path=='/' then return '' end
 if path:sub(1,1)=='/' then path=path:sub(2)end
 if not path:match('^[%w_]+[/%.%w_]*$') then return nil end
 return path:gsub('%.','/')
end
local syntax={chunk=true,return_statement=true,expression_list=true,table_constructor=true,field=true,
 function_definition=true,parameters=true,block=true,variable_declaration=true,assignment_statement=true,
 variable_list=true,identifier=true,function_call=true,method_index_expression=true,arguments=true,
 string=true,string_content=true,number=true,if_statement=true,elseif_statement=true,else_statement=true,
 binary_expression=true,unary_expression=true,dot_index_expression=true,bracket_index_expression=true,
 parenthesized_expression=true,for_statement=true,for_generic_clause=true,empty_statement=true,
 ['true']=true,['false']=true,['nil']=true}
local function lower(alignment,options,ti)
 local supplied=options.ast_indexes and options.ast_indexes[ti]
 local association=alignment.variants[ti].ast
 if type(supplied)~='table' or type(supplied.source)~='string' or not association then fail('source_evidence_required') end
 if workflow.hash(supplied.source)~=supplied.source_hash or supplied.source_hash~=association.source_hash or supplied.version~=association.version then fail('source_hash_mismatch') end
 local index=assert(ast.index(supplied.source,supplied.version))
 local nodes=index.nodes
 if #nodes>12000 or #index.features.bindings>256 then fail('resource_limit') end
 local root=named(index,nodes[1]);local top=root[1]
 if #root~=1 or not top or top.kind~='return_statement' then fail('unsupported_source') end
 local expr=child(index,top,nil,'expression_list');local values=expr and named(index,expr) or {}
 if #values~=1 then fail('unsupported_source') end
 local fn=values[1]
 if fn.kind=='table_constructor' then
  local fields=children(index,fn,nil,'field')
  if #fields~=1 or child(index,fields[1],'name').value~='run' then fail('unsupported_source') end
  fn=child(index,fields[1],'value')
 end
 if not fn or fn.kind~='function_definition' then fail('unsupported_source') end
 local params=named(index,child(index,fn,'parameters'))
 if #params~=1 or params[1].value~='ctx' then fail('unsupported_source') end
 local ctx_binding=params[1].binding
 local body=child(index,fn,'body')
 local parameters=options.parameters and options.parameters[ti] or {}
 local used,allowed,required,calls,call_by_node,checks,loops={},{},{},{},{},{},{}
 local required_seen={}
 local function require_key(key,node,origin)
  if not identifier(key) then fail('invalid_parameter') end
  if not required_seen[key] then required_seen[key]=true;required[#required+1]={key=key,required=true,origin=origin,node=node,source_hash=index.source_hash} end
 end
 for id,key in pairs(parameters)do
  if type(id)~='number' or not nodes[id] or (nodes[id].kind~='string' and nodes[id].kind~='number') or not identifier(key) then fail('invalid_parameter') end
 end
 local function method(n)
  local callee=child(index,n,'name')
  if callee and callee.kind=='method_index_expression' then
   local receiver=child(index,callee,'table');local name=child(index,callee,'method')
   if receiver.kind=='identifier' and receiver.binding==ctx_binding then return name.value end
  end
 end
 local function within(n,kind)
  while n and n.id~=body.id do if n.kind==kind then return true end;n=nodes[n.parent] end
  return false
 end
 for _,n in ipairs(nodes)do
  if n.named and not syntax[n.kind] then fail('unsupported_syntax') end
  if n.kind=='function_definition' and n.id~=fn.id then fail('unsupported_closure') end
  if n.kind=='identifier' and n.value:match('^_compiled_') then fail('reserved_identifier') end
  if n.kind=='identifier' and n.role=='declaration' and n.value=='ctx' and n.binding~=ctx_binding then fail('unsupported_alias') end
  if n.kind=='identifier' and n.binding==ctx_binding and n.id~=params[1].id then
   local parent=nodes[n.parent]
   if not parent or parent.kind~='method_index_expression' or n.field~='table' then fail('unsupported_alias') end
  end
  if n.kind=='identifier' and n.role and n.role:match('^global_') then
   if (n.value~='ipairs' and n.value~='type' and n.value~='assert') or not nodes[n.parent] or nodes[n.parent].kind~='function_call' or n.field~='name' then fail('unsupported_global') end
  end
  if n.kind=='assignment_statement' and nodes[n.parent].kind~='variable_declaration' then
   for _,target in ipairs(named(index,child(index,n,nil,'variable_list')))do
    if target.kind~='bracket_index_expression' then fail('unsupported_assignment') end
    local table_node=child(index,target,'table')
    if not table_node or table_node.kind~='identifier' or not table_node.binding or table_node.binding==ctx_binding then fail('unsupported_assignment') end
   end
  end
  if n.kind=='if_statement' or n.kind=='elseif_statement' then checks[#checks+1]=child(index,n,'condition') end
  if n.kind=='for_statement' then
   local clause=child(index,n,'clause')
   if not clause or clause.kind~='for_generic_clause' then fail('unsupported_loop') end
   local list=child(index,clause,nil,'expression_list');local items=list and named(index,list) or {}
   local iter=items[1];local name=iter and child(index,iter,'name')
   if #items~=1 or not name or name.kind~='identifier' or name.value~='ipairs' or name.binding then fail('unsupported_loop') end
   loops[n.id]=#loops+1
  end
  if n.kind=='function_call' then
   local m=method(n);local args=named(index,child(index,n,'arguments'))
   if m and within(n,'for_statement') then fail('effectful_loop_unsupported') end
   if m=='call' then
    if within(n,'for_statement') then fail('effectful_loop_unsupported') end
    if #args~=2 or not literal(index,args[1]) or not identifier(literal(index,args[1])) then fail('unsupported_call') end
    local declaration=nodes[n.parent] and nodes[nodes[n.parent].parent]
    if not declaration or declaration.kind~='assignment_statement' or nodes[declaration.parent].kind~='variable_declaration' then fail('call_binding_required') end
    local targets=named(index,child(index,declaration,nil,'variable_list'))
    local rhs=named(index,child(index,declaration,nil,'expression_list'))
    if #targets~=1 or #rhs~=1 or targets[1].kind~='identifier' then fail('call_binding_required') end
    allowed[args[1].id]=true
    local call={node=n.id,name=literal(index,args[1]),args=args[2],binding=targets[1].binding,occurrence=#calls+1}
    calls[#calls+1]=call;call_by_node[n.id]=call
   elseif m=='resolve' then
    if #args~=1 or not literal(index,args[1]) then fail('unsupported_context') end
    local key=literal(index,args[1]);allowed[args[1].id]=true;require_key(key,n.id,'source_context')
   elseif m=='observe' then
    local kind=literal(index,args[1])
    if #args~=3 or (kind~='dataflow' and kind~='branch') or args[3].kind~='table_constructor' then fail('unsupported_observation') end
    allowed[args[1].id]=true
    for _,field in ipairs(children(index,args[3],nil,'field'))do
     local key=child(index,field,'name');local value=child(index,field,'value')
     if not key or not ({producer=true,consumer=true,output=true,input=true,site=true})[key.value] then fail('unsupported_observation') end
     if value.kind=='string' then
      if not pointer(literal(index,value)) then fail('unsupported_observation') end;allowed[value.id]=true
     end
    end
   else
    local callee=child(index,n,'name')
    if not callee or callee.kind~='identifier' or callee.binding then fail('unsupported_call') end
    if callee.value=='ipairs' then
     if #args~=1 or not within(n,'for_generic_clause') then fail('unsupported_loop') end
    elseif callee.value~='type' and callee.value~='assert' then fail('unsupported_call') end
   end
  end
 end
 for _,n in ipairs(nodes)do
  if parameters[n.id] then
   -- A replacement is an executable provider resolution, even though the
   -- historical node was data. Apply the same pure-loop boundary as source calls.
   if within(n,'for_statement') then fail('effectful_loop_unsupported') end
   if allowed[n.id] then fail('invalid_parameter') end
   if parameters[n.id]==literal(index,n) then fail('invalid_parameter') end
   used[n.id]=true;require_key(parameters[n.id],n.id,'parameterized_literal')
  elseif n.kind=='string' and not allowed[n.id] then
   -- Only the outcome discriminant and type guards are program constants.
   local value=literal(index,n);local parent=nodes[n.parent]
   local safe=false
   if parent and parent.kind=='binary_expression' then
    for _,sibling in ipairs(named(index,parent))do
     if sibling.kind=='dot_index_expression' and child(index,sibling,'field').value=='status' and value=='succeeded' then safe=true end
     if sibling.kind=='function_call' then
      local callee=child(index,sibling,'name')
      if callee.kind=='identifier' and callee.value=='type' and ({table=true,string=true,number=true,boolean=true,['nil']=true})[value] then safe=true end
     end
    end
   end
   if not safe then fail('unsafe_literal') end;allowed[n.id]=true
  elseif n.kind=='number' and n.value~='0' and n.value~='1' then fail('unsafe_literal') end
 end
 for id in pairs(parameters)do if not used[id] then fail('invalid_parameter') end end
 local trace=alignment.traces[ti]
 if #calls>128 then fail('resource_limit') end
 if #calls~=#trace.steps or #calls==0 then fail('source_correspondence_required') end
 local sites=options.call_sites and options.call_sites[ti]
 if sites and #sites~=#calls then fail('source_correspondence_required') end
 for i,call in ipairs(calls)do
  local step=trace.steps[i]
  if sites and sites[i]~=call.node then fail('source_correspondence_required') end
  if step.status~='succeeded' or not step.event_id or not step.output_event_id or not step.descriptor or step.descriptor.id~=call.name then fail('source_correspondence_required') end
  if type(step.descriptor.version)~='string' or not identifier(step.descriptor.id) or not identifier(step.descriptor.target) or not identifier(step.descriptor.effect) then fail('capability_evidence_required') end
  local known={}
  for _,entry in ipairs(trace.evidence or {})do if entry.event_id then known[entry.event_id]=true end end
  if not known[step.event_id] or not known[step.output_event_id] then fail('source_correspondence_required') end
  call.evidence={step.event_id,step.output_event_id};call.descriptor=step.descriptor
 end
 -- Lexically tracked source dependencies. Reassignment of locals is forbidden;
 -- allowed table mutations accumulate dependencies and are labelled transformed.
 local producers,dependencies,transformed={},{},{}
 for i,call in ipairs(calls)do producers[call.binding]=i;dependencies[call.binding]={[i]=true} end
 local function deps(n)
  local out={}
  if n.kind=='identifier' and n.binding then union(out,dependencies[n.binding]) end
  for _,id in ipairs(n.children)do union(out,deps(nodes[id])) end
  return out
 end
 -- A bounded monotone fixed point also covers dependencies carried between
 -- loop iterations. No reaching-value equivalence is inferred from this union.
 local previous_count=-1
 for _=1,#index.features.bindings+1 do
  for _,n in ipairs(nodes)do
   if n.kind=='for_generic_clause' then
    local source=deps(child(index,n,nil,'expression_list'))
    for _,v in ipairs(named(index,child(index,n,nil,'variable_list')))do dependencies[v.binding]=union(dependencies[v.binding] or {},source);transformed[v.binding]=true end
   elseif n.kind=='assignment_statement' then
    local rhs=deps(child(index,n,nil,'expression_list'))
    local ancestor=nodes[n.parent]
    while ancestor and ancestor.id~=body.id do
     if ancestor.kind=='if_statement' or ancestor.kind=='elseif_statement' then union(rhs,deps(child(index,ancestor,'condition'))) end
     ancestor=nodes[ancestor.parent]
    end
    for _,v in ipairs(named(index,child(index,n,nil,'variable_list')))do
     local target=v.kind=='identifier' and v or child(index,v,'table')
     if target and target.binding and not producers[target.binding] then
      dependencies[target.binding]=union(dependencies[target.binding] or {},rhs)
      if v.kind~='identifier' then union(dependencies[target.binding],deps(v)) end
      transformed[target.binding]=true
     elseif v.kind~='identifier' then fail('outcome_mutation_unsupported') end
    end
   end
  end
  local dependency_count=0
  for _,set in pairs(dependencies)do for _ in pairs(set)do dependency_count=dependency_count+1 end end
  if dependency_count==previous_count then break end
  previous_count=dependency_count
 end
 local function direct(n)
  local path={}
  while n.kind=='dot_index_expression' do
   table.insert(path,1,child(index,n,'field').value);n=child(index,n,'table')
  end
  if n.kind=='identifier' and producers[n.binding] and path[1]=='result' then
   table.remove(path,1);return producers[n.binding],table.concat(path,'/')
  end
 end
 local binding_map,unknowns={},{}
 local function validate_arg(n,consumer,input)
  local producer,output=direct(n)
  if producer then
   local found=0
   for _,binding in ipairs(alignment.bindings[ti] or {})do
    if binding.consumer==consumer and pointer(binding.input)==input then
     local observed=false;for _,entry in ipairs(trace.evidence or {})do if entry.event_id==binding.evidence then observed=true end end
     if binding.producer~=producer or pointer(binding.output)~=output or not observed or binding.provenance~='explicit_annotation' then fail('binding_evidence_required') end
     found=found+1
    end
   end
   if found~=1 then fail('binding_evidence_required') end
   binding_map[#binding_map+1]={consumer=consumer,producer=producer,input=input,output=output,kind='direct_source_and_observation',node=n.id}
  elseif n.kind=='table_constructor' then
   for _,field in ipairs(children(index,n,nil,'field'))do
    local name=child(index,field,'name');if not name or name.kind~='identifier' then fail('unsupported_argument') end
    validate_arg(child(index,field,'value'),consumer,input=='' and name.value or input..'/'..name.value)
   end
  else
   for origin in pairs(deps(n))do
    if origin>=consumer then fail('binding_evidence_required') end
    binding_map[#binding_map+1]={consumer=consumer,producer=origin,input=input,kind='source_transformation',node=n.id}
    unknowns[#unknowns+1]={code='transformed_value_lineage_unobserved',node=n.id,producer=origin,consumer=consumer}
   end
  end
 end
 for i,call in ipairs(calls)do validate_arg(call.args,i,'') end
 for _,binding in ipairs(binding_map)do binding.source_hash=index.source_hash;binding.span=nodes[binding.node].span end
 local maps,check_nodes={},{}
 for i,n in ipairs(checks)do check_nodes[n.id]=i end
 local loop_count=0;for _,n in ipairs(nodes)do if loops[n.id] then loop_count=loop_count+1;loops[n.id]=loop_count end end
 local emit
 local function ordinary(n)
  if n.kind=='string' then return string.format('%q',literal(index,n)) end
  if #n.children==0 then return n.value end
  local parts={};for _,id in ipairs(n.children)do parts[#parts+1]=emit(nodes[id]) end
  return table.concat(parts,n.kind=='block' and '\n' or ' ')
 end
 emit=function(n)
  if parameters[n.id] then return 'ctx:resolve('..string.format('%q',parameters[n.id])..')' end
  local call=call_by_node[n.id]
  if call then
   local site='observed_call_'..call.occurrence
   maps[#maps+1]={site=site,kind=options.residual_capabilities and options.residual_capabilities[call.name] and 'residual_model' or 'capability',node=n.id,span=n.span,source_hash=index.source_hash,evidence=call.evidence}
   return 'ctx:step('..string.format('%q',site)..', function()\nlocal _compiled_outcome = '..ordinary(n)..'\nif _compiled_outcome.status ~= "succeeded" then error("compiled_call_failed") end\nreturn _compiled_outcome\nend)'
  end
  if check_nodes[n.id] then
   local site='source_check_'..check_nodes[n.id]
   maps[#maps+1]={site=site,kind='source_check',node=n.id,span=n.span,source_hash=index.source_hash,evidence={source_hash=index.source_hash},observation='branch_outcome_not_inferred'}
   return 'ctx:step('..string.format('%q',site)..', function() return '..ordinary(n)..' end)'
  end
  if n.kind=='for_statement' then
   local clause=child(index,n,'clause');local loop_body=child(index,n,'body');local counter='_compiled_loop_'..loops[n.id]
   return 'do local '..counter..'=0\nfor '..ordinary(clause)..' do\n'..counter..'='..counter..'+1\nif '..counter..'>1024 then error("compiled_loop_limit") end\n'..emit(loop_body)..'\nend end'
  end
  return ordinary(n)
 end
 local source='return {run=function(ctx)\n'..emit(body)..'\nend}\n'
 if #source>262144 then fail('resource_limit') end
 for _,map in ipairs(maps)do
  local pos=assert(source:find(string.format('%q',map.site),1,true))
  local _,lines=source:sub(1,pos):gsub('\n','');map.generated_line=lines+1
 end
 return {source=source,required=required,maps=maps,calls=calls,bindings=binding_map,unknowns=unknowns,index=index,loops=loop_count}
end
function M.candidate(alignment,options)
 local ok,result=pcall(function()
  bounded({alignment,options});options=options or {}
  if type(options)~='table' then fail('invalid_options') end
  for key in pairs(options)do if not ({ast_indexes=true,parameters=true,call_sites=true,residual_capabilities=true})[key] then fail('unsupported_option') end end
  if type(alignment)~='table' or type(alignment.traces)~='table' or #alignment.traces<2 or #alignment.traces>8 or type(alignment.variants)~='table' or type(alignment.bindings)~='table' or type(alignment.common_regions)~='table' then fail('invalid_alignment') end
  if not alignment.ambiguity or alignment.ambiguity.mapping_possible~=false then fail('ambiguous_alignment') end
  for i=2,#alignment.traces do
   local variant=alignment.variants[i]
   if not variant or not variant.coverage or variant.coverage.left~=1 or variant.coverage.right~=1 then fail('incomplete_alignment') end
   if variant.relationships and variant.relationships.bindings.status=='different' then fail('binding_evidence_required') end
  end
  local incomplete={event_limit=true,step_limit=true,incomplete_observation=true,ambiguous_occurrence=true,unmatched_or_duplicate_terminal=true,imported_effect_and_revision_unavailable=true,effect_unavailable=true,outcome_not_proven=true}
  for _,unknown in ipairs(alignment.unknowns or {})do if incomplete[unknown.code] then fail('incomplete_evidence') end end
  local lowered,canonical={},nil
  for i=1,#alignment.traces do
   if options.ast_indexes~=nil then lowered[i]=lower(alignment,options,i)
   else lowered[i]=require('mining.compile_trace').lower(alignment,options,i) end
   local generated=assert(ast.index(lowered[i].source,'candidate'))
   if canonical and canonical~=generated.features.structure_hash then fail('source_structure_difference') end
   canonical=generated.features.structure_hash
  end
  local first=lowered[1]
  -- workflow.capabilities pins one version per ID, not one per call site. A
  -- repeated ID must have one consistent observed contract before constructing it.
  local pins={}
  for _,call in ipairs(first.calls)do
   local previous=pins[call.name]
   if previous then
    for _,field in ipairs({'version','target','effect'})do
     if previous[field]~=call.descriptor[field] then fail('capability_pin_conflict') end
    end
   else pins[call.name]=call.descriptor end
  end
  for name,enabled in pairs(options.residual_capabilities or {})do
   local found=false;for _,call in ipairs(first.calls)do if call.name==name then found=true end end
   if enabled~=true or not found then fail('invalid_residual_capability') end
  end
  for ti=2,#lowered do
   for i,call in ipairs(lowered[ti].calls)do
    local base=first.calls[i].descriptor
    for _,field in ipairs({'id','version','target','effect'})do
     if base[field]~=call.descriptor[field] then fail('capability_evidence_required') end
    end
   end
  end
  local manifest={schema_version=1,kind='mined_lua_candidate',activation_eligible=false,evaluated=false,capabilities={},sources={},bindings=first.bindings,limits={source_bytes=262144,loop_iterations=1024},compiler=first.mode or 'source-subset-v1'}
  local unknowns={}
  for _,u in ipairs(alignment.unknowns or {})do unknowns[#unknowns+1]=u end
  for i,item in ipairs(lowered)do
   manifest.sources[i]={trace=alignment.traces[i].id,scope=alignment.traces[i].scope,source_ref=alignment.traces[i].source,source_hash=item.index.source_hash,version=item.index.version}
   for _,u in ipairs(item.unknowns)do u.trace=i;unknowns[#unknowns+1]=u end
  end
  for _,call in ipairs(first.calls)do
   manifest.capabilities[call.name]=call.descriptor.version
   if options.residual_capabilities and options.residual_capabilities[call.name] then unknowns[#unknowns+1]={code='residual_model_decision',capability=call.name} end
  end
  unknowns[#unknowns+1]={code='candidate_requires_held_out_evaluation'}
  unknowns[#unknowns+1]={code='current_source_authority_must_be_revalidated_by_host'}
  unknowns[#unknowns+1]={code='unobserved_paths'}
  if first.loops>0 then unknowns[#unknowns+1]={code='loop_limit_synthesized',limit=1024} end
  return {source=first.source,source_hash=workflow.hash(first.source),manifest=manifest,source_map=first.maps,required_context=first.required,
   verifiers={{id='distinct_input_behavior',status='required'},{id='effect_safety',status='required'},{id='source_authority_and_revisions',status='required'}},unknowns=unknowns}
 end)
 if ok then return result end
 return nil,type(result)=='table' and result.code and result or {code='invalid_input'}
end
return M
