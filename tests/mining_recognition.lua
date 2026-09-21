local recognize=require('mining.recognize')
local align=require('mining.align')
local n=0
local function check(v,m) assert(v,m);n=n+1 end
local function trace(id,effect,word)
 local events={}
 for i,name in ipairs({'list','report'}) do
  local cid=id..':'..i
  events[#events+1]={kind='invocation.start',event_id=cid..'s',run_id=id,correlation_id=cid,payload={name=name,args={text=word}}}
  events[#events+1]={kind='invocation.admitted',event_id=cid..'a',run_id=id,correlation_id=cid,payload={descriptor={id=name,version='1',target='fixture',effect=i==1 and 'read' or effect}}}
  events[#events+1]={kind='invocation.terminal',event_id=cid..'t',run_id=id,correlation_id=cid,payload={status='succeeded',result=word}}
 end
 return {id=id,scope='fixture',revision=1,events=events}
end
local query=trace('query','pure','find missing replies')
local positive=trace('positive','pure','identify absent respondents')
local negative=trace('negative','write','find missing replies')
local ctx={scope='fixture',corpus={negative,positive},authorize=function()return true end,validate=function()return true end}
local result=assert(recognize.find({text='find missing replies',trace=query},ctx,'fixture'))
check(result[1].id=='positive','different words same process outranks same words different effects')
check(result[1].activation_eligible==false,'recognition grants no execution authority')
print('mining_recognition: '..n..' checks passed')
local function has(list,code) for _,u in ipairs(list)do if u.code==code then return true end end end
check(result.coverage.semantic_available==false,'semantic retrieval unavailable explicitly')
check(has(result[2].applicability.conflicts,'observed_process_difference'),'whole effect difference explicit')
local repeats=trace('repeats','pure','values')
for _,e in ipairs(trace('more','pure','other').events) do repeats.events[#repeats.events+1]=e end
repeats.events[#repeats.events+1]={kind='observation.dataflow',event_id='link',payload={source='explicit_annotation',links={producer='repeats:1',consumer='repeats:2',output='/value',input='/text'}}}
repeats.events[#repeats.events+1]={kind='observation.branch',event_id='branch',payload={source='explicit_annotation',value=false,links={site='conditional'}}}
local aligned=assert(align.compare({positive,repeats,query}))
check(#aligned.traces[2].steps==4,'repeated occurrences retained')
check(#aligned.bindings[2]==1 and aligned.bindings[2][1].producer==1,'explicit occurrence lineage retained')
check(#aligned.bindings[1]==0,'equal values do not infer lineage')
check(aligned.variants[2].branches[1].value==false,'branch outcome retained')
check(has(aligned.unknowns,'unobserved_paths'),'unobserved paths explicit')
check(aligned.ambiguity.mapping_possible,'repeated alignment ambiguity explicit')
local unique=assert(align.compare({query,positive}))
check(unique.ambiguity.mapping_possible==false and unique.ambiguity.semantic_equivalence=='unknown','unique observed mapping separated from semantic uncertainty')
local suggestions=assert(recognize.find({text='ordinary request'},ctx,'fixture'))
check(has(suggestions[1].unknowns,'request_structure_unavailable'),'ordinary requests return unresolved suggestions')
local called=false
local denied={scope='fixture',corpus={positive},authorize=function() return false end,validate=function()return true end,retrieve=function()called=true end}
check(recognize.find({text='x'},denied,'fixture')==nil and not called,'scope checked before retrieval')
local live=true
local revoked={scope='fixture',authorize=function()return live end,validate=function()return true end,retrieve=function()live=false;return {sources={positive}}end}
check(recognize.find({text='x'},revoked,'fixture')==nil,'post retrieval revocation denies')
local stale=false
local changing={scope='fixture',corpus={positive,negative},authorize=function()return true end,validate=function(s)return not(stale and s.id=='positive')end,
 load=function(s)if s.id=='negative' then stale=true end;return s.events end}
check(recognize.find({text='x'},changing,'fixture')==nil,'later callback invalidates earlier result')
local foreign=trace('foreign','pure','x');foreign.scope='other'
local loaded=false
local isolated={scope='fixture',corpus={foreign},authorize=function()return true end,validate=function()return true end,load=function()loaded=true end}
check(#assert(recognize.find({text='x'},isolated,'fixture'))==0 and not loaded,'foreign candidates never loaded')
local many={};for i=1,40 do many[i]=positive end
local bounded={scope='fixture',corpus=many,authorize=function()return true end,validate=function()return true end}
local limited=assert(recognize.find({text='x'},bounded,'fixture'))
check(limited.coverage.truncated and limited.coverage.considered==32,'corpus bound explicit')
local huge=trace('huge','pure','x');for i=1,520 do huge.events[i]={kind='fixture',event_id=tostring(i)}end
check(has(assert(align.normalize(huge)).unknowns,'event_limit'),'event work bound explicit')
local db=assert(require('db').open(os.tmpname()))
local evidence=require('evidence');assert(evidence.configure{db=db})
for _,e in ipairs(positive.events)do e.scope='fixture';assert(evidence.append(e))end
local actual=assert(recognize.native('positive','fixture',db))
check(#actual==6 and actual[1].origin=='native','actual persisted evidence adapter')
local native_source={id='persisted',scope='fixture',revision=1,events=actual}
check(assert(align.compare({query,native_source})).variants[2].matched==2,'persisted envelope aligns')
check(recognize.native('positive','other',db)==nil,'native ownership enforced')
local imports=require('imports');imports.configure{db=db}
local json=require('json');local path=os.tmpname();local f=assert(io.open(path,'wb'))
f:write(json.encode({type='assistant',sessionId='recognition-import',message={content={{type='tool_use',id='call1',name='list',input={text='fixture'}}}}}),'\n');f:close()
assert(imports.ingest{source={path=path,root='/tmp',session='recognition-import'},format='claude',scope='fixture',redaction={literals={}}})
local imported={id='imported',scope='fixture',revision=1,events=imports.read('fixture')}
local normalized=assert(align.normalize(imported))
check(#normalized.steps==1 and has(normalized.unknowns,'imported_effect_and_revision_unavailable'),'actual imported normalization preserves unknown effect')
local imported_ctx={scope='fixture',corpus={imported},authorize=function()return true end,validate=function()return true end}
local imported_suggestions=assert(recognize.find({text='list'},imported_ctx,'fixture'))
check(#imported_suggestions==2 and imported_suggestions[2].kind=='fragment' and imported_suggestions[2].tentative,'imported gaps still yield tentative fragment suggestions')
os.remove(path)
local historical_path=os.tmpname();local h=assert(io.open(historical_path,'wb'))
for _,event in ipairs(actual) do h:write(json.encode(event),'\n') end
h:write(json.encode({schema_version=1,event_id='historical-branch',run_id='positive',kind='observation.branch',payload={value=false,links={site='if'},source='explicit_annotation'}}),'\n')
h:close()
assert(imports.ingest{source={path=historical_path,root='/tmp',session='positive'},format='boggart',scope='fixture-history',redaction={literals={}}})
local historical=assert(align.normalize{id='history',scope='fixture-history',events=imports.read('fixture-history')})
check(#historical.steps==2 and historical.branches[1].value==false,'actual Boggart historical import keeps occurrences and branch')
check(historical.steps[1].descriptor==nil and historical.steps[1].status=='imported_unverified','historical admission never promoted to native certainty')
os.remove(historical_path)
local false_trace=trace('false','pure','x');false_trace.events[3].payload.result=false
check(assert(align.normalize(false_trace)).steps[1].output==false,'false output preserved')
local ast=require('mining.ast')
local same_ast=assert(ast.index('if input then report() end','1'))
local other_ast=assert(ast.index('if not input then report() end','2'))
query.code_hash=same_ast.source_hash
positive.ast=same_ast;positive.code_hash=same_ast.source_hash
local different_predicate=trace('different-predicate','pure','find missing replies')
different_predicate.ast=other_ast;different_predicate.code_hash=other_ast.source_hash
ctx.corpus={different_predicate,positive}
local ranked=assert(recognize.find({text='find missing replies',trace=query,ast=same_ast},ctx,'fixture'))
check(ranked[1].id=='positive','AST predicate evidence breaks otherwise equal effect sequence tie')
check(has(ranked[2].applicability.conflicts,'ast_structure_difference'),'AST predicate difference requires applicability review')
positive.code_hash='stale'
local unassociated=assert(align.compare({query,positive},{same_ast,same_ast}))
check(has(unassociated.unknowns,'ast_source_association_unavailable'),'unassociated AST is not structural evidence')
local memory=require('memory')
local port=memory.open{db=db,scope='fixture',export=false,authorize=function()return true end}
local memory_revision=port:put{source_id='memory-source',source_ref='run:positive',text='fixture process'}
local memory_context={scope='fixture',authorize=function()return true end,
 validate=function(source,scope)
  local rows=assert(db:query('SELECT revision,deleted FROM scoped_memory WHERE scope=? AND source_id=?',{scope,source.id}))
  return #rows==1 and rows[1].deleted==0 and rows[1].revision==source.revision
 end,
 retrieve=function(text,options)
  check(options.mode=='text','retriever uses actual memory text mode')
  local page=port:search(text,options);local sources={}
  for _,hit in ipairs(page.hits)do sources[#sources+1]={id=hit.source_id,revision=hit.revision,scope=hit.scope,source_ref=hit.source_ref,run_id='positive'}end
  page.coverage.backend=page.backend
  return {sources=sources,coverage=page.coverage}
 end,
 load=function(source,options)return recognize.native(source.run_id,options.scope,db)end}
local memory_results=assert(recognize.find({text='fixture'},memory_context,'fixture'))
check(#memory_results==1 and memory_results[1].source.revision==memory_revision,'real scoped memory source hydration works')
check(memory_results.coverage.backend=='local' and memory_results.coverage.retrieval.text=='literal_substring','real memory fallback remains accurately labelled')
local function lineage_trace(id,producer)
 local t={id=id,scope='fixture',revision=1,events={}}
 for i,name in ipairs({'read_A','read_B','report'}) do
  local cid=id..':'..i
  t.events[#t.events+1]={kind='invocation.start',event_id=cid..'s',correlation_id=cid,payload={name=name,args={text='value'}}}
  t.events[#t.events+1]={kind='invocation.admitted',event_id=cid..'a',correlation_id=cid,payload={descriptor={id=name,version='1',target='fixture',effect=i==3 and 'pure' or 'read'}}}
  t.events[#t.events+1]={kind='invocation.terminal',event_id=cid..'t',correlation_id=cid,payload={status='succeeded',result='value'}}
 end
 t.events[#t.events+1]={kind='observation.dataflow',event_id=id..':binding',payload={source='explicit_annotation',links={producer=id..':'..producer,consumer=id..':3',output='',input='/text'}}}
 return t
end
local lineage_reference=lineage_trace('lineage-reference',1)
local lineage_positive=lineage_trace('z-lineage-positive',1)
local lineage_negative=lineage_trace('a-lineage-negative',2)
local lineage_ctx={scope='fixture',corpus={lineage_negative,lineage_positive},authorize=function()return true end,validate=function()return true end}
local lineage_rank=assert(recognize.find({text='report',trace=lineage_reference},lineage_ctx,'fixture'))
check(lineage_rank[1].id=='z-lineage-positive','different producer for same report input lowers workflow rank')
check(lineage_rank[1].relationships.bindings.status=='compatible','mapped matching lineage is compatible')
check(lineage_rank[2].relationships.bindings.status=='different' and has(lineage_rank[2].applicability.conflicts,'binding_relationship_difference'),'different lineage is an explicit applicability conflict')
local binding_region=lineage_rank[2].alignment.common_regions[1]
check(binding_region.relationships.bindings[1].comparison.status=='different' and not binding_region.relationships.bindings[1].boundary_dependency,'relationship comparison attached to applicable region')
local missing_lineage=lineage_trace('missing-lineage',1);table.remove(missing_lineage.events)
check(assert(align.compare({lineage_reference,missing_lineage})).variants[2].relationships.bindings.status=='unknown','missing lineage remains unknown')
local duplicate_lineage=lineage_trace('duplicate-lineage',1)
duplicate_lineage.events[#duplicate_lineage.events+1]=duplicate_lineage.events[#duplicate_lineage.events]
check(assert(align.compare({lineage_reference,duplicate_lineage})).variants[2].relationships.bindings.status=='unknown','multiple annotations for one consumer remain unknown')
local repeated_relationship=assert(align.compare({repeats,repeats}))
check(repeated_relationship.variants[2].relationships.bindings.status=='unknown','ambiguous occurrence alignment cannot establish relationship compatibility')
local function context_event(t,value,dependency,source_revision)
 t.events[#t.events+1]={kind='context.terminal',event_id=t.id..':context',payload={value=value,provenance={key='participants',status='resolved',source='injected',source_revision=source_revision,dependencies={{key=dependency,source='injected',source_revision='1'}},capabilities={}}}}
end
local function branch_event(t,value)
 t.events[#t.events+1]={kind='observation.branch',event_id=t.id..':branch',payload={source='explicit_annotation',value=value,links={site='missing-respondents'}}}
end
context_event(lineage_reference,'Ada','expected_people','1');branch_event(lineage_reference,true)
context_event(lineage_positive,'Bo','expected_people','1');branch_event(lineage_positive,false)
context_event(lineage_negative,'Ada','actual_people','2');branch_event(lineage_negative,true)
local relationships=assert(align.compare({lineage_reference,lineage_positive,lineage_negative}))
local positive_rel=relationships.variants[2].relationships
local negative_rel=relationships.variants[3].relationships
check(positive_rel.branches.status=='different' and positive_rel.branches.comparisons[1].reason=='observed_branch_outcome_variant','opposite observed outcomes at identified branch site remain variants')
check(positive_rel.contexts.status=='compatible' and positive_rel.contexts.comparisons[1].value_status=='different','ordinary context value variation does not change dependency compatibility')
check(negative_rel.contexts.status=='different','context dependency identity and revision differences recorded')
lineage_ctx.corpus={lineage_positive}
local value_variant=assert(recognize.find({text='report',trace=lineage_reference},lineage_ctx,'fixture'))[1]
check(not has(value_variant.applicability.conflicts,'context_dependency_variant'),'value-only context change does not create applicability conflict')
lineage_ctx.corpus={lineage_negative}
check(has(assert(recognize.find({text='report',trace=lineage_reference},lineage_ctx,'fixture'))[1].applicability.conflicts,'context_dependency_variant'),'dependency variation requires current applicability check')
local branch_duplicate=lineage_trace('branch-duplicate',1);branch_event(branch_duplicate,true);branch_event(branch_duplicate,false)
check(assert(align.compare({lineage_reference,branch_duplicate})).variants[2].relationships.branches.status=='unknown','repeated branch sites require occurrence evidence')
local partial_context=lineage_trace('partial-context',1);context_event(partial_context,'Ada','expected_people',nil)
check(assert(align.compare({lineage_reference,partial_context})).variants[2].relationships.contexts.status=='unknown','missing source revision does not become matching revision')
local nested_context=lineage_trace('nested-context',1);context_event(nested_context,'Ada','expected_people','1')
nested_context.events[#nested_context.events].payload.provenance.dependencies[1].dependencies={{key='nested',source_revision='1'}}
check(assert(align.compare({lineage_reference,nested_context})).variants[2].relationships.contexts.status=='unknown','unsupported nested dependency coverage stays unknown')
local cap_context=lineage_trace('cap-context',1);context_event(cap_context,'Ada','expected_people','1')
cap_context.events[#cap_context.events].payload.provenance.capabilities={{id='read_A',version='1',invocation_id='outside-this-trace'}}
check(assert(align.compare({lineage_reference,cap_context})).variants[2].relationships.contexts.status=='unknown','context capability outside observed mapping stays unknown')
local cached_child_context=lineage_trace('cached-child-context',1)
context_event(cached_child_context,'Ada','expected_people','1')
local cached_child=cached_child_context.events[#cached_child_context.events].payload.provenance.dependencies[1]
cached_child.cache='hit';cached_child.dependencies={};cached_child.cached_dependencies={{key='nested-cached',source_revision='1'}}
check(assert(align.compare({lineage_reference,cached_child_context})).variants[2].relationships.contexts.status=='unknown','nested cached child dependencies stay unknown')
assert(evidence.configure{db=false});db:close()
print('mining_recognition: '..n..' checks passed (complete suite)')
