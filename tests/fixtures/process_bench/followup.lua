-- Sanitized deterministic traces; compiler sees training traces only.
local M={}
function M.candidate(source_backed)
 local ast,align,compile=require('mining.ast'),require('mining.align'),require('mining.compile')
 local source=[[return function(ctx)
 local args=ctx:resolve('args')
 local sent=ctx:call('bench.send',args)
 return sent.result
 end]]
 local index=source_backed and assert(ast.index(source,'1'))
 local traces={}
 for i=1,2 do
  local id='training-'..i
  traces[i]={id=id,scope='process-bench',revision='1',code_hash=index and index.source_hash,events={
   {origin='native',event_id=id..':1',kind='invocation.start',run_id=id,correlation_id=id..':call',payload={name='bench.send',args={recipient='training-person'}}},
   {origin='native',event_id=id..':2',kind='invocation.admitted',run_id=id,correlation_id=id..':call',payload={descriptor={id='bench.send',version='1',target='local',effect='write'}}},
   {origin='native',event_id=id..':3',kind='invocation.terminal',run_id=id,correlation_id=id..':call',payload={status='succeeded',result={text='All done'}}},
  }}
 end
 local indexes=index and {index,index} or nil
 local aligned,ae=align.compare(traces,indexes);assert(aligned,ae and ae.code)
 local result,err=compile.candidate(aligned,indexes and {ast_indexes=indexes} or nil);assert(result,err and err.code);return result
end
function M.dataset(source_backed)
 local rows={}
 for i,split in ipairs({'train','train','validation','heldout','heldout'}) do
  local id=i<3 and 'training-'..i or 'evaluation-'..i
  rows[i]={id=id,split=split,task=id,session=id,variant=id,scope='process-bench',trace=id,
   applicable=i~=5,mode='fresh',evidence_ref='fixture:'..id,
   context={enabled=i~=5,[source_backed and 'args' or 'call_1_args']={recipient='current-person-'..i}},
   expected={recipient='current-person-'..i},costs={candidate={execution=2,failed_runs=0,fallback=0,repairs=0},baseline={execution=10,failed_runs=0,fallback=0,repairs=0}},baseline_verified=true,baseline_evidence_ref='fixture:baseline:'..id}
 end
 return {id='followup-fixture',revision='1',examples=rows,costs={unit='fixture-credit',horizon=10,
  candidate={discovery=1,imports=1,mining=2,synthesis=3,evaluation=1},
  baseline={discovery=0,imports=0,mining=0,synthesis=0,evaluation=0}}}
end
function M.policy()
 return {id='fixture-policy',revision='1',adapters={['bench.send']={id='mock-send',revision='1',version='1',isolation='mock',effect='write',
  call=function(args)return {status='succeeded',result={text='All done',recipient=args.recipient}}end}},
  applicability={id='followup',revision='1',check=function(context)return context.enabled end},
  verifiers={{id='recipient-and-output',revision='1',verify=function(observed,expected)
   local wrong=false
   for _,call in ipairs(observed.calls)do if call.args.recipient~=expected.recipient then wrong=true end end
   return {passed=not wrong and observed.result and observed.result.text=='All done',wrong_recipient=wrong}
  end}},
  source_authority={id='fixture-authority',revision='1',check=function()return true,'fixture:authority' end}}
end
return M
