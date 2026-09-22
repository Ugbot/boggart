-- Synthetic evidence only; reusable actual-runtime harness for independent probes.
local workflow,cap,invoke=require('workflow'),require('capability'),require('invoke')
local json=require('json')
local function fixture()
 require('perm').state().guards=false
 local db=assert(require('db').open(os.tmpname()))
 assert(require('evidence').configure{db=db})
 local f={calls={},responses={},unavailable=false}
 f.authority=invoke.context{state={mode='auto',guards=false},ledger=assert(require('quota').open(db)),
  policy=assert(require('policy').compile{{id='novel-fixture',revision=1,capabilities={allow={'*'}}}})}
 assert(cap.register({id='novel.fixture.read',version='1',revision='synthetic-1',effect='read'},function(a)
  f.calls[#f.calls+1]=a
  if f.unavailable then return {available=false,scope=a.scope,source_refs={'synthetic:unavailable'}} end
  if f.read then return f.read(a) end
  return (assert(f.responses[a.kind],'missing synthetic response'))
 end))
 local shared_file=assert(io.open('examples/workflows/novel_context.lua','rb'));local shared=shared_file:read('*a');shared_file:close()
 f.sources={}
 for _,kind in ipairs({'character','timeline','cleanup','wordcount'}) do
  local file=assert(io.open('examples/workflows/novel_'..kind..'.lua','rb'));local source=file:read('*a');file:close()
  source=shared..'\n'..source;f.sources[kind]=source
  assert(workflow.register{id='novel.'..kind,version='1',source=source,source_hash=workflow.hash(source),capabilities={['novel.fixture.read']='1'}})
 end
 function f.scope(novel,revision)return {novel=novel or 'Harbor',corpus='synthetic',revision=revision or 'r1'} end
 function f.envelope(kind,data,scope)
  data.scope=scope or f.scope();data.available=true;data.source_refs=data.source_refs or {'synthetic:'..kind};f.responses[kind]=data;return data
 end
 function f.run(kind,config,scope,authority)
  return assert(workflow.start('novel.'..kind,{authority=authority or f.authority,context={scope=scope or f.scope(),config=config or {},
   evidence={revision='synthetic-provider-1',cache='none',resolve=function(ctx,request)
    local out=ctx:call('novel.fixture.read',request)
    if out.status~='succeeded' then return nil,out.error end
    return out.result
   end}},source_revisions={evidence='synthetic-live'}})):snapshot()
 end
 return f
end
if rawget(_G,'NOVEL_FIXTURE_ONLY') then return fixture end
local f=fixture();local checks=0
local function check(x,label)assert(x,label);checks=checks+1 end
for kind,source in pairs(f.sources) do
 check(assert(workflow.resolve('novel.'..kind,'1')).source_hash==workflow.hash(source),'combined source identity '..kind)
end
local function result(kind,config,scope)
 local s=f.run(kind,config,scope);check(s.status=='succeeded',json.encode(s));return s.result
end
f.envelope('character',{assertions={
 {character_id='ada',attribute='eyes',value='green',source_refs={'chapter:1'}},
 {character_id='ada',attribute='eyes',value='brown',source_refs={'chapter:2'}},
 {character_id='ada',attribute='occupation',value='pilot',source_refs={'chapter:3'}},
 {character_id='other',attribute='eyes',value='blue',source_refs={'chapter:4'}}}})
local c=result('character',{character_id='ada',attributes={'eyes','occupation','age'}})
assert(c.attributes,json.encode(c))
check(#c.attributes.eyes.assertions==2 and #c.conflicts==1,'competing assertions retained')
check(c.attributes.occupation.assertions[1].value=='pilot' and c.attributes.age.status=='absent','detail and absent facts')
check(result('character',{character_id='ada'},f.scope('Other')).status=='scope_mismatch','novel scope isolated')
check(result('character',{character_id='ada'},f.scope(nil,'r2')).status=='scope_mismatch','revision scope isolated')
f.unavailable=true;check(result('character',{character_id='ada'}).status=='unavailable','unavailable distinct');f.unavailable=false
f.envelope('timeline',{events={{id='arrival'},{id='meeting'},{id='departure'},{id='unknown'}},constraints={
 {before='arrival',after='meeting',source_refs={'chapter:1'}},{before='meeting',after='departure',source_refs={'chapter:2'}}}})
local t=result('timeline');check(#t.conflicts==0 and #t.layers[1]==2 and #t.layers==3,'partial ordered layers')
check(t.events[4].date==nil,'unknown date not invented')
f.responses.timeline.constraints[3]={before='departure',after='arrival',source_refs={'chapter:3'}}
t=result('timeline');check(#t.conflicts>0 and #t.conflicts[1].source_refs==3,'sourced cycle')
f.responses.timeline.events[#f.responses.timeline.events+1]={id='downstream'}
f.responses.timeline.constraints[#f.responses.timeline.constraints+1]={before='departure',after='downstream',source_refs={'chapter:4'}}
t=result('timeline');check(#t.conflicts[1].source_refs==3 and #t.unordered==4,'blocked descendant is not cyclic edge')
f.responses.timeline.constraints[#f.responses.timeline.constraints+1]={before='missing',after='unknown',source_refs={'chapter:5'}}
t=result('timeline');check(t.conflicts[1].kind=='unknown_event' and t.conflicts[1].source_refs[1]=='chapter:5','unknown endpoint sourced')
f.envelope('cleanup',{text='Ada is 31.  \r\nShe owns 2 boats.\t\r\n'})
local clean=result('cleanup',{facts={'Ada is 31.','She owns 2 boats.'}})
check(clean.proposed=='Ada is 31.\nShe owns 2 boats.\n' and clean.changed_facts==0 and #clean.diff>0,'safe cleanup and diff')
check(clean.proposed:match('Ada is 31%.') and clean.proposed:match('She owns 2 boats%.'),'independent fixture fact verification')
local drift=result('cleanup',{facts={'Ada is 31.','She owns 2 boats.'},proposed_text='Ada is 32.\nShe owns 2 boats.\n'})
check(drift.changed_facts==1 and not drift.checks.fact_preserving,'semantic drift not certified')
local unchecked=result('cleanup',{facts={'No such assertion'},proposed_text='Ada is 31.\nShe owns 2 boats.\nNew narrative.'})
check(unchecked.fact_coverage=='unavailable' and unchecked.checks.semantic_status=='unverified' and not unchecked.checks.fact_preserving,'missing facts and added semantics remain unverified')
check(clean.original==f.responses.cleanup.text and not clean.applied and clean.review_required,'source unchanged and review required')
for _,case in ipairs({{'',0},{'one two\nthree',3},{"don't O’Neil mother-in-law",3},{'rock--roll — sea',3},{'café café Ελληνικά Привет',4},{'你好 世界',2},{'hi😀there\194\160end',3},{"'alone' - end-",2},{'123 4.5',3},{'مرحبا بالعالم',2},{'नमस्ते दुनिया',2},{'α;β',2},{'𠀀 𝟙',2},{'é́ ‐ a‐b',2},{'a’́b',2}}) do
 f.envelope('wordcount',{text=case[1]});check(result('wordcount').count==case[2],'independent word count '..case[1])
end
f.envelope('wordcount',{text='bad\255'});check(result('wordcount').status=='invalid_utf8','invalid UTF8 rejected')
f.envelope('wordcount',{text='fresh'});local before=#f.calls;result('wordcount');f.responses.wordcount.text='fresh now';check(result('wordcount').count==2 and #f.calls==before+2,'fresh provider per run')
local denied=invoke.context({state={mode='auto',guards=false,tool_policy={['novel.fixture.read']='deny'}}},f.authority)
before=#f.calls;local d=f.run('wordcount',{},nil,denied);check(#f.calls==before and d.result.status=='unavailable','provider authority enforced')
print('workflow_novel: '..checks..' checks passed')
