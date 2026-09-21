local ast,align,workflow=require('mining.ast'),require('mining.align'),require('workflow')
local compile=require('mining.compile')
local count=0
local function check(value,message) assert(value,message);count=count+1 end
local function fixture(id,person)
 local source=([[return {run=function(ctx)
 local replies=ctx:call('compile.replies',{query='historical-secret'})
 local interpretation=ctx:call('compile.interpret',{replies=replies.result,expected='%s'})
 if #interpretation.result.missing > 0 then
  return {missing=interpretation.result.missing,filename='historical-file'}
 end
 return {missing={}}
 end}]]):format(person)
 local index=assert(ast.index(source,'1'))
 local trace={id=id,scope='compile-fixture',revision='1',code_hash=index.source_hash,events={}}
 local function event(kind,cid,payload)
  trace.events[#trace.events+1]={event_id=id..':'..#trace.events+1,kind=kind,run_id=id,correlation_id=cid,payload=payload}
 end
 for i,name in ipairs({'compile.replies','compile.interpret'})do
  event('invocation.start',id..i,{name=name,args={private='historical-secret'}})
  event('invocation.admitted',id..i,{descriptor={id=name,version='1',target='local',effect='pure'}})
  event('invocation.terminal',id..i,{status='succeeded',result={}})
 end
 event('observation.dataflow',nil,{source='explicit_annotation',links={producer=id..1,consumer=id..2,output='',input='/replies'}})
 local parameters,sites={},{}
 for _,node in ipairs(index.nodes)do
  if node.kind=='string' then
   local value=index.source:sub(node.span.start_byte,node.span.end_byte-1)
   if value=="'historical-secret'" then parameters[node.id]='query'
   elseif value=="'historical-file'" then parameters[node.id]='filename'
   elseif value=="'"..person.."'" then parameters[node.id]='expected' end
  elseif node.kind=='function_call' then sites[#sites+1]=node.id end
 end
 return trace,index,parameters,sites
end
local a,ai,ap,ac=fixture('a','historical-Ada')
local b,bi,bp,bc=fixture('b','historical-Ben')
local aligned=assert(align.compare({a,b},{ai,bi}))
local options={ast_indexes={ai,bi},parameters={ap,bp},call_sites={ac,bc},residual_capabilities={['compile.interpret']=true}}
local candidate,err=compile.candidate(aligned,options)
check(candidate,err and err.code)
check(not candidate.source:find('historical-secret',1,true),'historical secret absent')
check(not candidate.source:find('historical-',1,true),'historical recipients and filenames absent')
check(candidate.source_hash==workflow.hash(candidate.source),'hash exact source')
check(candidate.manifest.activation_eligible==false,'inactive until evaluation')
local cap,invoke=require('capability'),require('invoke')
local seen={}
assert(cap.register({id='compile.replies',version='1',effect='pure'},function(args) seen.query=args.query;return args.query end))
assert(cap.register({id='compile.interpret',version='1',effect='pure'},function(args)
 seen.expected=args.expected;seen.replies=args.replies
 local missing={};for _,name in ipairs(args.expected)do if not args.replies[name] then missing[#missing+1]=name end end
 return {missing=missing}
end))
assert(workflow.register{id='compiled-fixture',version='1',source=candidate.source,source_hash=candidate.source_hash,capabilities=candidate.manifest.capabilities})
local authority=invoke.context{state={mode='auto',guards=false}}
local function run(context,auth)
 return assert(workflow.start('compiled-fixture',{authority=auth or authority,context=context})):snapshot()
end
local first=run{query={Ada=true},expected={'Ada','Cam'},filename='current-a.txt'}
check(first.status=='succeeded' and first.result.missing[1]=='Cam' and first.result.filename=='current-a.txt','candidate uses distinct first context')
local second=run{query=function()return {Dee=true}end,expected={revision='p1',resolve=function()return {'Dee','Eve'}end},filename='current-b.txt'}
check(second.status=='succeeded' and second.result.missing[1]=='Eve' and second.result.filename=='current-b.txt','candidate uses injected providers and distinct second context')
check(seen.expected[2]=='Eve' and seen.replies.Dee,'output bound to later model input')
local empty=run{query={Fox=true},expected={'Fox'},filename='unused.txt'}
check(empty.status=='succeeded' and #empty.result.missing==0 and empty.result.filename==nil,'stable source branch executes different outcome')
check(#empty.steps==3,'two emitted call steps and source check step')
check(run{query={},filename='x'}.status=='failed','missing required context fails')
local denied=invoke.context{state={mode='auto',guards=false,tool_policy={['compile.interpret']='deny'}}}
local denied_state=run({query={},expected={'X'},filename='x'},denied)
check(denied_state.status=='failed' and denied_state.invocations[2].error.code=='permission_error' and denied_state.invocations[2].receipt.dispatched==false,'residual model policy denied without fallback')
local function refused(alignment,opts,code)
 local value,why=compile.candidate(alignment,opts)
 check(value==nil and why and why.code==code,'refusal '..code..' got '..tostring(why and why.code))
end
local function clone(v)if type(v)~='table'then return v end;local out={};for k,x in pairs(v)do out[k]=clone(x)end;return out end
local bad=clone(options);bad.parameters[1][next(ap)]=nil
refused(aligned,bad,'unsafe_literal')
bad=clone(options);bad.call_sites[1][1]=99999
refused(aligned,bad,'source_correspondence_required')
bad=clone(options);bad.parameters[1][ac[1]]='attack'
refused(aligned,bad,'invalid_parameter')
bad=clone(options);bad.ast_indexes[1].source=bad.ast_indexes[1].source..' '
refused(aligned,bad,'source_hash_mismatch')
local missing=clone(aligned);missing.bindings[1]={};missing.traces[1].bindings={}
refused(missing,options,'binding_evidence_required')
local ambiguous=clone(aligned);ambiguous.ambiguity.mapping_possible=true
refused(ambiguous,options,'ambiguous_alignment')
local cycle={};cycle.self=cycle
refused(cycle,options,'invalid_input')
local hostile=clone(options);hostile.parameters[1][next(ap)]='x\nerror()'
refused(aligned,hostile,'invalid_parameter')
for _,entry in ipairs(candidate.source_map)do
 check(entry.synthesized or entry.evidence and entry.source_hash and entry.node,'every emitted step has source or synthesized provenance')
end
print('mining_compile: '..count..' checks passed')
-- Generic stable list comparison: actual source index and alignment feed the
-- compiler; source-derived list dependencies remain distinct from direct links.
local file=assert(io.open('examples/workflows/compiled_followup.lua','rb'))
local loop_source=file:read('a');file:close()
local li=assert(ast.index(loop_source,'1'))
local function loop_trace(id)
 local tr=fixture(id,'historical-person')
 tr.code_hash=li.source_hash
 for _,event in ipairs(tr.events)do
  local descriptor=event.payload.descriptor
  if descriptor then descriptor.id=descriptor.id=='compile.replies' and 'compile.followup.replies' or 'compile.followup.report' end
 end
 table.remove(tr.events) -- no direct-value annotation for a transformed list
 return tr
end
local la,lb=loop_trace('loop-a'),loop_trace('loop-b')
local laligned=assert(align.compare({la,lb},{li,li}))
local lc,le=compile.candidate(laligned,{ast_indexes={li,li},residual_capabilities={['compile.followup.report']=true}})
check(lc,le and le.code)
local transformed=false
for _,binding in ipairs(lc.manifest.bindings)do if binding.kind=='source_transformation' then transformed=true end end
check(transformed,'derived list dependency identified without claiming direct observed equivalence')
local report_calls=0
assert(cap.register({id='compile.followup.replies',version='1',effect='pure'},function(args)return args.query end))
assert(cap.register({id='compile.followup.report',version='1',effect='pure'},function(args)report_calls=report_calls+1;return args.style..':'..table.concat(args.missing,',') end))
assert(workflow.register{id='compiled-loops',version='1',source=lc.source,capabilities=lc.manifest.capabilities})
local function loop_run(context)return assert(workflow.start('compiled-loops',{authority=authority,context=context})):snapshot()end
local lr=loop_run{expected_people={'Uma','Vic'},query={'Uma'},style='brief',filename='current-report.txt'}
check(lr.status=='succeeded' and lr.result.missing[1]=='Vic' and lr.result.report=='brief:Vic','source-bound set difference remains ordinary Lua')
local complete=loop_run{expected_people={'Wes'},query={'Wes'}}
check(complete.status=='succeeded' and #complete.result.missing==0 and report_calls==1,'fresh complete list avoids residual model and unused context')
local large={};for i=1,1025 do large[i]='person'..i end
check(loop_run{expected_people=large,query={}}.status=='failed','synthesized loop guard bounds current inputs')
local function compile_source(source)
 local idx=assert(ast.index(source,'1'));local ta,tb=loop_trace('bad-a'),loop_trace('bad-b');ta.code_hash=idx.source_hash;tb.code_hash=idx.source_hash
 return compile.candidate(assert(align.compare({ta,tb},{idx,idx})),{ast_indexes={idx,idx}})
end
check(compile_source(loop_source:gsub('for _,person in ipairs%(replies.result%) do','while true do'))==nil,'unsupported arbitrary loop refused')
check(compile_source(loop_source:gsub('responded%[person%]=true','local effect=ctx:call("compile.followup.replies",{})'))==nil,'repeated effect loop refused')
check(compile_source(loop_source:gsub('local responded={}','local alias=ctx;local responded={}'))==nil,'context alias cannot bypass mediated call syntax')
check(compile_source(loop_source:gsub('local responded={}','local _compiled_loop_1={};local responded={}'))==nil,'reserved generated identifiers cannot collide')
print('mining_compile final: '..count..' checks passed')
local mismatch=clone(aligned);mismatch.traces[2].steps[1].descriptor.version='2'
refused(mismatch,options,'capability_evidence_required')
bad=clone(options);bad.transformations={{code='untrusted code'}}
refused(aligned,bad,'unsupported_option')
bad=clone(options);bad.residual_capabilities['unknown.model']=true
refused(aligned,bad,'invalid_residual_capability')
bad=clone(options);bad.parameters[1][next(ap)]='historical-secret'
-- Pick the actual secret node so a renamed required key cannot retain its value.
for id,key in pairs(ap)do if key=='query' then bad.parameters[1][id]='historical-secret' end end
refused(aligned,bad,'invalid_parameter')
local missing_event=clone(aligned);missing_event.traces[1].steps[1].event_id='nonexistent'
refused(missing_event,options,'source_correspondence_required')
local wrong_binding=clone(aligned);wrong_binding.bindings[2][1].output='/wrong'
refused(wrong_binding,options,'binding_evidence_required')
local unbound=clone(aligned);unbound.variants[1].ast=nil
refused(unbound,options,'source_evidence_required')
local too_large=clone(options);too_large.ast_indexes[1].source=string.rep('x',262145)
refused(aligned,too_large,'resource_limit')
print('mining_compile hardened: '..count..' checks passed')
local incomplete=clone(aligned);incomplete.unknowns[#incomplete.unknowns+1]={code='incomplete_observation'}
refused(incomplete,options,'incomplete_evidence')
check(compile_source(loop_source:gsub('responded%[person%]=true','responded[person]=ctx:resolve("repeated")'))==nil,'provider effects cannot hide inside pure loop lowering')
print('mining_compile complete: '..count..' checks passed')
-- Review regressions: one manifest pin must describe every occurrence of an ID.
local function conflicting_pin(field)
 local ta,idx,pa=fixture('pin-a','historical-person')
 local tb,_,pb=fixture('pin-b','historical-person')
 idx=assert(ast.index(idx.source:gsub('compile.interpret','compile.replies'),'1'))
 ta.code_hash=idx.source_hash;tb.code_hash=idx.source_hash
 for _,tr in ipairs({ta,tb})do
  local occurrence=0
  for _,event in ipairs(tr.events)do
   if event.payload.descriptor then
    occurrence=occurrence+1
    event.payload.descriptor.id='compile.replies'
    if occurrence==2 then event.payload.descriptor[field]=field=='version' and '2' or field=='effect' and 'read' or 'different-target' end
   end
  end
 end
 local observed=assert(align.compare({ta,tb},{idx,idx}))
 check(not observed.ambiguity.mapping_possible,'different descriptors have unique observed occurrence mapping')
 return compile.candidate(observed,{ast_indexes={idx,idx},parameters={pa,pb}})
end
local function parameterized_loop(iterator)
 local source
 if iterator then source=loop_source:gsub('ipairs%(replies.result%)','ipairs({"historical-loop"})')
 else source=loop_source:gsub('responded%[person%]=true','responded[person]="historical-loop"') end
 local idx=assert(ast.index(source,'1'));local parameter={}
 for _,node in ipairs(idx.nodes)do
  if node.kind=='string' and idx.source:sub(node.span.start_byte,node.span.end_byte-1)=='"historical-loop"' then parameter[node.id]='loop_provider' end
 end
 local ta,tb=loop_trace('parameter-loop-a'),loop_trace('parameter-loop-b');ta.code_hash=idx.source_hash;tb.code_hash=idx.source_hash
 return compile.candidate(assert(align.compare({ta,tb},{idx,idx})),{ast_indexes={idx,idx},parameters={parameter,parameter}})
end
local pin_results={}
for _,field in ipairs({'version','target','effect'})do
 local candidate,why=conflicting_pin(field);pin_results[#pin_results+1]={candidate=candidate,why=why,field=field}
end
local body_candidate,body_error=parameterized_loop(false)
local iterator_candidate,iterator_error=parameterized_loop(true)
-- Evaluate both regressions before asserting so failing-before output records
-- both independent bypasses against the unmodified compiler.
check(not pin_results[1].candidate and not body_candidate and not iterator_candidate,
 'review regressions: conflicting pin accepted='..tostring(pin_results[1].candidate~=nil)..
 ', loop body provider accepted='..tostring(body_candidate~=nil)..
 ', loop iterator provider accepted='..tostring(iterator_candidate~=nil))
for _,result in ipairs(pin_results)do
 check(result.candidate==nil and result.why.code=='capability_pin_conflict','refuse conflicting '..result.field..' for one capability ID')
end
check(body_error.code=='effectful_loop_unsupported','parameter injection cannot introduce provider effects in loop body')
check(iterator_error.code=='effectful_loop_unsupported','parameter injection cannot introduce provider effects in loop iterator')
print('mining_compile reviewed: '..count..' checks passed')
-- Initial crystallization from real native capability evidence: no workflow
-- registration, Lua source, source hash or AST exists for the recorded sequence.
local evidence,retention=require('evidence'),require('evidence_retention')
local native_db=assert(require('db').open(os.tmpname()))
assert(evidence.configure{db=native_db});assert(retention.configure{db=native_db})
local native_scope='compile-native-fixture'
local native_model_calls=0
assert(cap.register({id='compile.native.fetch',version='1',effect='pure'},function(args)return {text=args.text}end))
assert(cap.register({id='compile.native.model',version='1',effect='pure'},function(args)
 native_model_calls=native_model_calls+1;return {report=args.style..':'..args.text,filename=args.filename}
end))
local function record_native(text)
 local id=evidence.id('native-compile')
 invoke.with_correlation({run_id=id,scope=native_scope},function()
  local fetched=cap.call(authority,'compile.native.fetch','1',{text=text})
  local report=cap.call(authority,'compile.native.model','1',{text=fetched.result.text,style='historical-style',filename='historical-file'})
  assert(fetched.status=='succeeded' and report.status=='succeeded')
  assert(evidence.append{run_id=id,scope=native_scope,kind='observation.dataflow',payload={source='explicit_annotation',links={producer=fetched.receipt.invocation_id,consumer=report.receipt.invocation_id,output='/text',input='/text'}}})
 end)
 return {id=id,scope=native_scope,revision=1,events=assert(require('mining.recognize').native(id,native_scope,native_db))}
end
local native_a,native_b=record_native('historical-secret-A'),record_native('historical-secret-B')
local native_alignment=assert(align.compare({native_a,native_b}))
check(native_alignment.variants[1].ast==nil,'native initial sequence has no Lua source association')
local native_candidate,native_error=compile.candidate(native_alignment,{residual_capabilities={['compile.native.model']=true}})
check(native_candidate,'source-free native candidate: '..tostring(native_error and native_error.code))
check(not native_candidate.source:find('historical',1,true),'no historical arguments/results embedded in initial crystallization')
assert(workflow.register{id='compiled-native',version='1',source=native_candidate.source,capabilities=native_candidate.manifest.capabilities})
local function native_run(context)
 return assert(workflow.start('compiled-native',{authority=authority,scope=native_scope,context=context})):snapshot()
end
local current_args={text='stale-consumer',style='brief',filename='fresh-a.txt'}
local native_first=native_run{call_1_args={text='current-A'},call_2_args=current_args}
check(native_first.status=='succeeded' and native_first.result.report=='brief:current-A' and native_first.result.filename=='fresh-a.txt','initial candidate binds fresh producer and current independent arguments')
check(current_args.text=='stale-consumer','binding overlay does not mutate injected context')
local native_second=native_run{call_1_args=function()return {text='current-B'}end,call_2_args={revision='current-provider',resolve=function()return {style='detail',filename='fresh-b.txt'}end}}
check(native_second.status=='succeeded' and native_second.result.report=='detail:current-B' and native_second.result.filename=='fresh-b.txt','source-free candidate accepts fresh providers and distinct inputs')
check(native_model_calls==4,'observed residual model calls remain explicit')
for _,map in ipairs(native_candidate.source_map)do check(map.synthesized and map.evidence,'initial source steps labelled synthesized with evidence')end
print('mining_compile trace-first: '..count..' checks passed')
-- Independent native reads may both supply a later call. The second read's
-- current arguments remain injected; equal historical values never invent links.
assert(cap.register({id='compile.native.roster',version='1',effect='pure'},function(args)return {people=args.people}end))
assert(cap.register({id='compile.native.join',version='1',effect='pure'},function(args)return {summary=args.text..':'..table.concat(args.people,','),style=args.style}end))
local function record_join(text,people)
 local id=evidence.id('native-join')
 invoke.with_correlation({run_id=id,scope=native_scope},function()
  local fetched=cap.call(authority,'compile.native.fetch','1',{text=text})
  local roster=cap.call(authority,'compile.native.roster','1',{people=people})
  local joined=cap.call(authority,'compile.native.join','1',{text=fetched.result.text,people=roster.result.people,style='historical-style'})
  for _,link in ipairs({{fetched,'text'},{roster,'people'}})do
   assert(evidence.append{run_id=id,scope=native_scope,kind='observation.dataflow',payload={source='explicit_annotation',links={producer=link[1].receipt.invocation_id,consumer=joined.receipt.invocation_id,output='/'..link[2],input='/'..link[2]}}})
  end
 end)
 return {id=id,scope=native_scope,revision=1,events=assert(require('mining.recognize').native(id,native_scope,native_db))}
end
local join_a,join_b=record_join('old-A',{'Historical Ada'}),record_join('old-B',{'Historical Ben'})
local joined_alignment=assert(align.compare({join_a,join_b}))
local joined_candidate=assert(compile.candidate(joined_alignment))
check(#joined_candidate.manifest.bindings==2,'independent native reads supply two explicit later bindings')
local independent=false
for _,unknown in ipairs(joined_candidate.unknowns)do if unknown.code=='input_lineage_unobserved' and unknown.occurrence==2 then independent=true end end
check(independent,'independently injected second read retains unknown observed lineage')
assert(workflow.register{id='compiled-native-join',version='1',source=joined_candidate.source,capabilities=joined_candidate.manifest.capabilities})
local joined_run=assert(workflow.start('compiled-native-join',{authority=authority,scope=native_scope,context={call_1_args={text='fresh'},call_2_args={people={'Cal','Dee'}},call_3_args={text='stale',people={'Wrong'},style='current'}}})):snapshot()
check(joined_run.status=='succeeded' and joined_run.result.summary=='fresh:Cal,Dee' and joined_run.result.style=='current','two independent current reads bind into a fresh joined invocation')
local bad_native=clone(native_alignment);bad_native.bindings[2]={}
check(compile.candidate(bad_native)==nil,'missing one side of required native binding refused')
bad_native=clone(native_alignment);bad_native.bindings[1][1].producer=2
refused(bad_native,{},'binding_evidence_required')
bad_native=clone(native_alignment);bad_native.bindings[1][1].input='/nested/text'
refused(bad_native,{},'unsupported_binding_pointer')
bad_native=clone(native_alignment);bad_native.bindings[1][1].output='/text~1escaped'
refused(bad_native,{},'unsupported_binding_pointer')
bad_native=clone(native_alignment);bad_native.traces[1].steps[2].input.text='contradiction'
refused(bad_native,{},'binding_value_mismatch')
bad_native=clone(native_alignment);bad_native.traces[1].steps[1].output.text={evidence_marker='redacted'}
refused(bad_native,{},'binding_value_unavailable')
bad_native=clone(native_alignment);bad_native.traces[1].branches={{value=false}}
refused(bad_native,{},'trace_control_flow_unsupported')
bad_native=clone(native_alignment);bad_native.traces[1].steps[2].start_position=bad_native.traces[1].steps[1].start_position
refused(bad_native,{},'trace_control_flow_unsupported')
bad_native=clone(native_alignment);bad_native.traces[1].steps[1].origin='imported'
refused(bad_native,{},'capability_evidence_required')
bad_native=clone(native_alignment);bad_native.bindings[1][2]=clone(bad_native.bindings[1][1])
refused(bad_native,{},'binding_evidence_required')
check(native_run{call_1_args={text='fresh'}}.status=='failed','missing current consumer argument context fails before model dispatch')
local excessive={};for i=1,1025 do excessive[i]=i end
check(native_run{call_1_args=excessive,call_2_args={}}.status=='failed','current argument copying is bounded')
print('mining_compile trace hardened: '..count..' checks passed')
local function without_links(tr)
 tr=clone(tr);local events={}
 for _,event in ipairs(tr.events)do if event.kind~='observation.dataflow' then events[#events+1]=event end end
 tr.events=events;return tr
end
local independent_candidate=assert(compile.candidate(assert(align.compare({without_links(native_a),without_links(native_b)}))))
check(#independent_candidate.manifest.bindings==0,'equal observed values without annotations do not infer lineage')
assert(workflow.register{id='compiled-independent',version='1',source=independent_candidate.source,capabilities=independent_candidate.manifest.capabilities})
local independent_run=assert(workflow.start('compiled-independent',{authority=authority,scope=native_scope,context={call_1_args={text='producer'},call_2_args={text='independent',style='fresh',filename='new'}}})):snapshot()
check(independent_run.status=='succeeded' and independent_run.result.report=='fresh:independent','explicit current arguments govern an unbound later call')
assert(cap.register({id='compile.native.echo',version='1',effect='pure'},function(args)return args end))
local function record_root(text)
 local id=evidence.id('native-root')
 invoke.with_correlation({run_id=id,scope=native_scope},function()
  local first=cap.call(authority,'compile.native.fetch','1',{text=text})
  local second=cap.call(authority,'compile.native.echo','1',first.result)
  assert(evidence.append{run_id=id,scope=native_scope,kind='observation.dataflow',payload={source='explicit_annotation',links={producer=first.receipt.invocation_id,consumer=second.receipt.invocation_id,output='',input=''}}})
 end)
 return {id=id,scope=native_scope,revision=1,events=assert(require('mining.recognize').native(id,native_scope,native_db))}
end
local root_alignment=assert(align.compare({record_root('historical-root-A'),record_root('historical-root-B')}))
local root_candidate=assert(compile.candidate(root_alignment))
check(#root_candidate.required_context==1 and root_candidate.required_context[1].key=='call_1_args','whole-argument binding requires no unused consumer context')
assert(workflow.register{id='compiled-root',version='1',source=root_candidate.source,capabilities=root_candidate.manifest.capabilities})
local root_run=assert(workflow.start('compiled-root',{authority=authority,scope=native_scope,context={call_1_args={text='fresh-root'}}})):snapshot()
check(root_run.status=='succeeded' and root_run.result.text=='fresh-root','whole-result binding feeds whole current argument object')
local native_pin=clone(native_alignment)
for _,trace in ipairs(native_pin.traces)do trace.steps[2].descriptor.id=trace.steps[1].descriptor.id;trace.steps[2].descriptor.version='2' end
refused(native_pin,{},'capability_pin_conflict')
print('mining_compile final trace: '..count..' checks passed')
-- Review regression: a producer may succeed with a missing current bound field.
-- Refuse before consumer dispatch instead of silently deleting its argument.
local calls_before_drift=native_model_calls
local drifted=native_run{call_1_args={},call_2_args={style='current',filename='current'}}
check(drifted.status=='failed' and native_model_calls==calls_before_drift,'missing current bound output must not dispatch downstream model')
local flexible_calls=0
assert(cap.register({id='compile.native.flexible',version='1',effect='pure'},function(args)return args.returned end))
assert(cap.register({id='compile.native.consume',version='1',effect='pure'},function(args)flexible_calls=flexible_calls+1;return {value=args.value}end))
local function record_flexible(root)
 local id=evidence.id('native-flexible')
 invoke.with_correlation({run_id=id,scope=native_scope},function()
  local first=cap.call(authority,'compile.native.flexible','1',{returned=root and {value='observed'} or {nested={value='observed'}}})
  local second=cap.call(authority,'compile.native.consume','1',root and first.result or {value=first.result.nested.value})
  assert(evidence.append{run_id=id,scope=native_scope,kind='observation.dataflow',payload={source='explicit_annotation',links={producer=first.receipt.invocation_id,consumer=second.receipt.invocation_id,output=root and '' or '/nested/value',input=root and '' or '/value'}}})
 end)
 return {id=id,scope=native_scope,revision=1,events=assert(require('mining.recognize').native(id,native_scope,native_db))}
end
local nested_candidate=assert(compile.candidate(assert(align.compare({record_flexible(false),record_flexible(false)}))))
local whole_candidate=assert(compile.candidate(assert(align.compare({record_flexible(true),record_flexible(true)}))))
assert(workflow.register{id='compiled-flexible-nested',version='1',source=nested_candidate.source,capabilities=nested_candidate.manifest.capabilities})
assert(workflow.register{id='compiled-flexible-whole',version='1',source=whole_candidate.source,capabilities=whole_candidate.manifest.capabilities})
local function flexible_run(id,returned)
 return assert(workflow.start(id,{authority=authority,scope=native_scope,context={call_1_args={returned=returned},call_2_args={}}})):snapshot()
end
for _,value in ipairs({false,0,{current='table'}})do
 local accepted=flexible_run('compiled-flexible-nested',{nested={value=value}})
 check(accepted.status=='succeeded' and (type(value)=='table' and accepted.result.value.current=='table' or accepted.result.value==value),'bound leaf accepts current false/zero/new type without historical type overfitting')
end
for _,returned in ipairs({{nested={}},{nested='not-a-table'}, {}})do
 local before=flexible_calls
 check(flexible_run('compiled-flexible-nested',returned).status=='failed' and flexible_calls==before,'missing leaf/intermediate shape stops before downstream dispatch')
end
for _,returned in ipairs({false,0,'not-a-table'})do
 local before=flexible_calls
 check(flexible_run('compiled-flexible-whole',returned).status=='failed' and flexible_calls==before,'whole-input binding enforces argument table before dispatch')
end
local whole_false=flexible_run('compiled-flexible-whole',{value=false})
check(whole_false.status=='succeeded' and whole_false.result.value==false,'whole-input object preserves a false member')
print('mining_compile bound guards: '..count..' checks passed')
local provider_calls=0
local blocked_provider=native_run{call_1_args={},call_2_args=function()provider_calls=provider_calls+1;return {style='unused'}end}
check(blocked_provider.status=='failed' and provider_calls==0,'bound path validated before potentially effectful consumer argument provider')
local before_nil=flexible_calls
check(flexible_run('compiled-flexible-whole',nil).status=='failed' and flexible_calls==before_nil,'nil whole result cannot reach consumer')
check(flexible_run('compiled-flexible-whole',{}).status=='succeeded','whole-input guard does not overfit historical object fields')
print('mining_compile current bindings: '..count..' checks passed')
