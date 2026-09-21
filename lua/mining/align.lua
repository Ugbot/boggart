-- Bounded, observations-only alignment. No source or candidate is executed.
local M={}
local MAX_EVENTS,MAX_TRACES,MAX_STEPS=512,8,128
local function unknown(t,code,ref) t.unknowns[#t.unknowns+1]={code=code,ref=ref} end
local function scalar(x) return type(x)=='string' or type(x)=='number' or type(x)=='boolean' end
local function descriptor(d)
 return type(d)=='table' and type(d.id)=='string' and scalar(d.version) and type(d.target)=='string' and type(d.effect)=='string' and d.effect~='unknown'
end
local function same(a,b)
 local x,y=a.descriptor,b.descriptor
 return descriptor(x) and descriptor(y) and x.id==y.id and x.version==y.version and x.target==y.target and x.effect==y.effect
end
-- Accept the real native evidence envelope or imports.read normalized records.
function M.normalize(trace)
 if type(trace)~='table' or type(trace.events)~='table' then return nil,{code='invalid_trace'} end
 local t={id=trace.id,steps={},branches={},contexts={},step_occurrences={},workflows={},bindings={},evidence={},unknowns={},source=trace.source_ref,scope=trace.scope}
 local pending,ends,annotations={},{},{}
 local events=trace.events
 if #events>MAX_EVENTS then unknown(t,'event_limit') end
 for i=1,math.min(#events,MAX_EVENTS) do
  local e=events[i]
  if type(e)~='table' then return nil,{code='invalid_event'} end
  if e.scope and e.scope~=trace.scope then return nil,{code='scope_mismatch'} end
  local historical=type(e.kind)=='string' and e.kind:sub(1,11)=='historical.'
  local kind=historical and e.kind:sub(12) or e.kind
  local p=historical and type(e.value)=='table' and e.value or type(e.payload)=='table' and e.payload or {}
  local observation=e.source_observation or {}
  local ref=e.event_id or e.id
  local key=e.correlation_id or e.operation_id
  t.evidence[#t.evidence+1]={event_id=ref,origin=e.origin,provenance=e.provenance,source_refs=e.source_refs,run_id=e.run_id,source_observation=e.source_observation,representation=e.representation}
  if kind=='invocation.start' or kind=='tool.request' then
   if #t.steps>=MAX_STEPS then unknown(t,'step_limit');break end
   local s={occurrence=#t.steps+1,id=key,event_id=ref,step_id=e.step_id or observation.step_id,parent_id=e.parent_id or e.parent,attempt_id=e.attempt_id or observation.attempt_id,
    start_position=i,name=p.name or e.name,input=p.args or e.value,status='unobserved',origin=e.origin}
   t.steps[#t.steps+1]=s
   if not key or pending[key] then unknown(t,'ambiguous_occurrence',ref) else pending[key]=s end
   if historical or kind=='tool.request' then unknown(t,'imported_effect_and_revision_unavailable',ref) end
  elseif kind=='invocation.admitted' then
   if pending[key] and not historical then pending[key].descriptor=p.descriptor end
  elseif kind=='invocation.terminal' or kind=='tool.result' then
   local s=pending[key]
   if s and not ends[key] then
    s.terminal_position=i;s.output=p.result;if kind=='tool.result' then s.output=e.value end;s.output_event_id=ref;s.status=p.status or (p.receipt and p.receipt.status) or 'imported_unverified'
    if historical then s.status='imported_unverified' end
    ends[key]=s
   else unknown(t,'unmatched_or_duplicate_terminal',ref) end
  elseif kind=='step.start' then t.step_occurrences[#t.step_occurrences+1]={event_id=ref,step_id=e.step_id,parent_id=e.parent_id,payload=p}
  elseif kind=='workflow.start' then t.workflows[#t.workflows+1]={event_id=ref,payload=p}
  elseif kind=='observation.branch' then
   t.branches[#t.branches+1]={event_id=ref,step_id=e.step_id,value=p.value,links=p.links,source=p.source,origin=e.origin,imported=historical or e.origin=='imported'}
  elseif kind=='observation.dataflow' then annotations[#annotations+1]={event_id=ref,payload=p,imported=historical}
  elseif kind=='context.terminal' then t.contexts[#t.contexts+1]={event_id=ref,payload=p,imported=historical or e.origin=='imported'}
  elseif kind=='coverage.incomplete' then unknown(t,'incomplete_observation',ref)
  end
  if e.artifact_refs then unknown(t,'artifact_not_resolved',ref) end
  if e.source_refs then for j=1,math.min(#e.source_refs,64) do
   if e.source_refs[j].observed_variant then unknown(t,'observed_variant',ref) end
  end end
 end
 for _,s in ipairs(t.steps) do
  if not descriptor(s.descriptor) then unknown(t,'effect_unavailable',s.event_id) end
  if s.status~='succeeded' then unknown(t,'outcome_not_proven',s.event_id) end
 end
 -- Links are only accepted as explicit annotations, naming observed producer and consumer occurrences.
 for _,a in ipairs(annotations) do
  local p=a.payload;local l=p.links
  local producer=type(l)=='table' and ends[l.producer]
  local consumer=type(l)=='table' and pending[l.consumer]
  if not a.imported and p.source=='explicit_annotation' and producer and consumer and producer.terminal_position<consumer.start_position and producer.status=='succeeded'
   and type(l.output)=='string' and type(l.input)=='string' then
   t.bindings[#t.bindings+1]={producer=producer.occurrence,consumer=consumer.occurrence,output=l.output,input=l.input,
    evidence=a.event_id,provenance='explicit_annotation'}
  else unknown(t,'lineage_annotation_unresolved',a.event_id) end
 end
 unknown(t,'capability_implementation_revision_unavailable')
 unknown(t,'unobserved_paths')
 if #t.bindings==0 then unknown(t,'value_lineage_unavailable') end
 if #t.contexts==0 then unknown(t,'context_dependencies_unavailable') end
 return t
end
local function summarize(items)
 local status=#items>0 and 'compatible' or 'unknown'
 for _,item in ipairs(items) do
  if item.status=='different' then return 'different' end
  if item.status=='unknown' then status='unknown' end
 end
 return status
end
local function repeated(steps)
 for i=1,#steps do for j=i+1,#steps do if same(steps[i],steps[j]) then return true end end end
 return false
end
-- Only observed, unambiguous occurrence correspondences can compare lineage.
local function relationships(left,right,mapping,ambiguous)
 local out={bindings={comparisons={}},branches={comparisons={}},contexts={comparisons={}},mapping=mapping}
 local used={}
 for _,a in ipairs(left.bindings) do
  local item={left=a,status='unknown',reason='missing_or_ambiguous_correspondence'}
  local target=mapping[a.consumer];local candidates={}
  if not ambiguous and target and mapping[a.producer] then
   for j,b in ipairs(right.bindings) do
    if b.consumer==target and b.input==a.input then candidates[#candidates+1]={index=j,binding=b} end
   end
   -- Multiple annotations for one input are not a unique reaching definition.
   local count=0
   for _,b in ipairs(left.bindings) do if b.consumer==a.consumer and b.input==a.input then count=count+1 end end
   if #candidates==1 and count==1 then
    local candidate=candidates[1];local b=candidate.binding
    local producer_mapped=false
    for _,target_occurrence in pairs(mapping) do if target_occurrence==b.producer then producer_mapped=true end end
    item.right=b;used[candidate.index]=true
    if producer_mapped then
     item.status=mapping[a.producer]==b.producer and a.output==b.output and 'compatible' or 'different'
     item.reason=item.status=='compatible' and 'same_observed_lineage' or 'different_observed_producer_or_output'
    end
   end
  end
  out.bindings.comparisons[#out.bindings.comparisons+1]=item
 end
 for i,b in ipairs(right.bindings) do if not used[i] then
  out.bindings.comparisons[#out.bindings.comparisons+1]={right=b,status='unknown',reason='no_unique_reference_binding'}
 end end
 local function unique_pairs(a,b,key,compare,destination)
  local seen={}
  for _,x in ipairs(a) do
   local id=key(x);local matches={};local count=0
   if id then
    for _,z in ipairs(a) do if key(z)==id then count=count+1 end end
    for j,y in ipairs(b) do if key(y)==id then matches[#matches+1]={index=j,value=y} end end
   end
   local item={left=x,status='unknown',reason='missing_or_repeated_identity'}
   if id and count==1 and #matches==1 then
    local match=matches[1];seen[match.index]=true;item.right=match.value
    compare(item,x,match.value)
   end
   destination[#destination+1]=item
  end
  for j,y in ipairs(b) do if not seen[j] then destination[#destination+1]={right=y,status='unknown',reason='no_unique_reference_identity'} end end
 end
 local function branch_key(b)
  if not b.imported and b.source=='explicit_annotation' and type(b.links)=='table' and type(b.links.site)=='string' then return b.links.site end
 end
 unique_pairs(left.branches,right.branches,branch_key,function(item,a,b)
  if scalar(a.value) and scalar(b.value) then
   item.status=a.value==b.value and 'compatible' or 'different'
   item.reason=item.status=='different' and 'observed_branch_outcome_variant' or 'same_observed_branch_outcome'
  end
 end,out.branches.comparisons)
 local function context_key(c)
  local p=c.payload.provenance
  if not c.imported and type(p)=='table' and type(p.key)=='string' and p.status=='resolved' then return p.key end
 end
 local function revision(a,b)
  if not scalar(a) or not scalar(b) then return 'unknown' end
  return a==b and 'compatible' or 'different'
 end
 local function dependencies(p)
  local input=p.cache=='hit' and p.cached_dependencies or p.dependencies
  local map,uncertain={},false
  if type(input)~='table' then return map,true end
  if #input>64 then uncertain=true end
  for i=1,math.min(#input,64) do
   local dep=input[i]
   if type(dep)~='table' or type(dep.key)~='string' or map[dep.key] then uncertain=true
   else
    map[dep.key]=dep
    local children=dep.dependencies
    if dep.cache=='hit' then
     children=dep.cached_dependencies
     if type(children)~='table' then uncertain=true end
    end
    if children and (type(children)~='table' or #children>0) then uncertain=true end
   end
  end
  return map,uncertain
 end
 unique_pairs(left.contexts,right.contexts,context_key,function(item,a,b)
  local x,y=a.payload.provenance,b.payload.provenance
  local checks={{field='source_identity',status=scalar(x.source) and scalar(y.source) and (x.source==y.source and 'compatible' or 'different') or 'unknown'},
   {field='source_revision',status=revision(x.source_revision,y.source_revision)}}
  if x.provider_revision~=nil or y.provider_revision~=nil then checks[#checks+1]={field='provider_revision',status=revision(x.provider_revision,y.provider_revision)} end
  local xd,xunknown=dependencies(x);local yd,yunknown=dependencies(y)
  for key,dep in pairs(xd) do
   local other=yd[key]
   checks[#checks+1]={field='dependency',key=key,status=not other and (yunknown and 'unknown' or 'different') or revision(dep.source_revision,other.source_revision)}
   if other and (dep.source~=nil or other.source~=nil) then checks[#checks+1]={field='dependency_source',key=key,status=revision(dep.source,other.source)} end
   if other and (dep.provider_revision~=nil or other.provider_revision~=nil) then checks[#checks+1]={field='dependency_provider_revision',key=key,status=revision(dep.provider_revision,other.provider_revision)} end
  end
  for key in pairs(yd) do if not xd[key] then checks[#checks+1]={field='dependency',key=key,status=xunknown and 'unknown' or 'different'} end end
  if xunknown or yunknown then checks[#checks+1]={field='dependency_coverage',status='unknown'} end
  local xc=x.cache=='hit' and x.cached_capabilities or x.capabilities
  local yc=y.cache=='hit' and y.cached_capabilities or y.capabilities
  if type(xc)~='table' or type(yc)~='table' or #xc>64 or #yc>64 then
   checks[#checks+1]={field='capability_dependencies',status='unknown'}
  else
   local function occurrence(trace,id)
    if not id then return nil end
    local found
    for i,step in ipairs(trace.steps) do if step.id==id then if found then return nil end;found=i end end
    return found
   end
   local correspondence_complete=not ambiguous
   for _,cap in ipairs(xc) do
    local index=type(cap)=='table' and occurrence(left,cap.invocation_id)
    if not index or not mapping[index] then correspondence_complete=false end
   end
   for _,cap in ipairs(yc) do
    local index=type(cap)=='table' and occurrence(right,cap.invocation_id);local found=false
    for _,target in pairs(mapping) do if index and target==index then found=true end end
    if not found then correspondence_complete=false end
   end
   local paired={}
   for _,cap in ipairs(xc) do
    local status='unknown';local li=type(cap)=='table' and occurrence(left,cap.invocation_id)
    if not ambiguous and li and mapping[li] then
     local matches={}
     for j,other in ipairs(yc) do
      if type(other)=='table' and occurrence(right,other.invocation_id)==mapping[li] then matches[#matches+1]=j end
     end
     if #matches==1 then
      local j=matches[1];local other=yc[j];paired[j]=true
      status=scalar(cap.id) and scalar(other.id) and scalar(cap.version) and scalar(other.version) and (cap.id==other.id and cap.version==other.version and 'compatible' or 'different') or 'unknown'
     elseif #matches==0 and correspondence_complete then status='different' end
    end
    checks[#checks+1]={field='capability_dependency',status=status}
   end
   for j in ipairs(yc) do if not paired[j] then checks[#checks+1]={field='capability_dependency',status=correspondence_complete and 'different' or 'unknown'} end end
  end
  item.details=checks;item.status=summarize(checks);item.reason='context_dependency_comparison'
  item.value_status=scalar(a.payload.value) and scalar(b.payload.value) and (a.payload.value==b.payload.value and 'compatible' or 'different') or 'unknown'
  -- Values are observations, not dependency identities or process compatibility.
 end,out.contexts.comparisons)
 for _,category in ipairs({'bindings','branches','contexts'}) do out[category].status=summarize(out[category].comparisons) end
 return out
end
function M.compare(traces,ast_indexes)
 if type(traces)~='table' or #traces<2 or #traces>MAX_TRACES then return nil,{code='trace_limit'} end
 local out={common_regions={},variants={},bindings={},evidence={},unknowns={},traces={},coverage={complete=false},activation_eligible=false}
 for i,tr in ipairs(traces) do
  local t,e=M.normalize(tr);if not t then return nil,e end
  out.traces[i]=t;out.bindings[i]=t.bindings;out.evidence[i]=t.evidence
  out.variants[i]={branches=t.branches,contexts=t.contexts,step_occurrences=t.step_occurrences,workflows=t.workflows,unmatched={}}
  for _,u in ipairs(t.unknowns) do out.unknowns[#out.unknowns+1]={trace=i,code=u.code,ref=u.ref} end
  local ast=ast_indexes and ast_indexes[i]
  if ast~=nil and type(ast)~='table' then return nil,{code='invalid_ast'} end
  if ast and (not traces[i].code_hash or ast.source_hash~=traces[i].code_hash) then
   out.unknowns[#out.unknowns+1]={trace=i,code='ast_source_association_unavailable'};ast=nil
  end
  if ast then
   if type(ast.nodes)~='table' or #ast.nodes>20000 or type(ast.features)~='table' or type(ast.features.structure_hash)~='string' or type(ast.unknowns)~='table' or #ast.unknowns>20000 then return nil,{code='invalid_ast'} end
   out.variants[i].ast={source_hash=ast.source_hash,version=ast.version,structure_hash=ast.features and ast.features.structure_hash}
   for j=1,math.min(#ast.unknowns,128) do out.unknowns[#out.unknowns+1]={trace=i,code='ast_dynamic_region',detail=ast.unknowns[j]} end
  else out.unknowns[#out.unknowns+1]={trace=i,code='ast_unavailable'} end
 end
 local mapping_ambiguous=false
 local base=out.traces[1].steps
 for ti=2,#out.traces do
  local other=out.traces[ti].steps
  local pair_ambiguous=repeated(base) or repeated(other)
  local left_ast,right_ast=out.variants[1].ast,out.variants[ti].ast
  if left_ast and right_ast then
   out.variants[ti].ast_structure_equal=left_ast.structure_hash==right_ast.structure_hash
   if not out.variants[ti].ast_structure_equal then out.unknowns[#out.unknowns+1]={trace=ti,code='ast_structure_difference'} end
  end
  local dp={};for i=0,#base do dp[i]={[0]=0} end
  for j=0,#other do dp[0][j]=0 end
  for i=1,#base do for j=1,#other do
   dp[i][j]=same(base[i],other[j]) and dp[i-1][j-1]+1 or math.max(dp[i-1][j],dp[i][j-1])
  end end
  local pairs,useda,usedb={}, {}, {};local i,j=#base,#other
  while i>0 and j>0 do
   if same(base[i],other[j]) then table.insert(pairs,1,{i,j});useda[i]=true;usedb[j]=true;i=i-1;j=j-1
   else
    if dp[i-1][j]==dp[i][j-1] and dp[i-1][j]>0 then pair_ambiguous=true end
    if dp[i-1][j]>=dp[i][j-1] then i=i-1 else j=j-1 end
   end
  end
  mapping_ambiguous=mapping_ambiguous or pair_ambiguous
  local mapping={};for _,pair in ipairs(pairs) do mapping[pair[1]]=pair[2] end
  local relations=relationships(out.traces[1],out.traces[ti],mapping,pair_ambiguous)
  out.variants[ti].relationships=relations
  out.variants[ti].mapping_ambiguous=pair_ambiguous
  local regions={};local region
  for _,pair in ipairs(pairs) do
   if not region or pair[1]~=region.left_finish+1 or pair[2]~=region.right_finish+1 then
    region={traces={1,ti},left_start=pair[1],left_finish=pair[1],right_start=pair[2],right_finish=pair[2],occurrences={}}
    regions[#regions+1]=region;out.common_regions[#out.common_regions+1]=region
   end
   region.left_finish=pair[1];region.right_finish=pair[2];region.occurrences[#region.occurrences+1]=pair
  end
  for _,r in ipairs(regions) do
   r.relationships={bindings={},branches=relations.branches,contexts=relations.contexts,control_context_scope='trace_pair'}
   for _,item in ipairs(relations.bindings.comparisons) do
    local a,b=item.left,item.right
    local function inside(binding,start,finish) return binding and (binding.consumer>=start and binding.consumer<=finish or binding.producer>=start and binding.producer<=finish) end
    if inside(a,r.left_start,r.left_finish) or inside(b,r.right_start,r.right_finish) then
     r.relationships.bindings[#r.relationships.bindings+1]={comparison=item,
      boundary_dependency=not(a and b and a.consumer>=r.left_start and a.consumer<=r.left_finish and a.producer>=r.left_start and a.producer<=r.left_finish and b.consumer>=r.right_start and b.consumer<=r.right_finish and b.producer>=r.right_start and b.producer<=r.right_finish)}
    end
   end
  end
  for k=1,#other do if not usedb[k] then out.variants[ti].unmatched[#out.variants[ti].unmatched+1]=k end end
  out.variants[ti].matched=#pairs
  out.variants[ti].coverage={left=#base>0 and #pairs/#base or 0,right=#other>0 and #pairs/#other or 0}
 end
 out.coverage.max_events=MAX_EVENTS;out.coverage.max_steps=MAX_STEPS
 out.ambiguity={possible=mapping_ambiguous,mapping_possible=mapping_ambiguous,
  reason=mapping_ambiguous and 'repeated_signature_or_optimal_path_tie' or 'unique_observed_alignment',
  conservative=true,semantic_equivalence='unknown'}
 return out
end
return M
