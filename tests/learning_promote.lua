package.path='lua/?.lua;lua/?/init.lua;'..package.path
local registry=require('learning.registry')
local fixture=dofile('tests/fixtures/process_bench/followup.lua')
local count=0
local function check(v,m)assert(v,m);count=count+1 end
local path=os.tmpname();local db=assert(require('db').open(path))
local allowed,qualified=true,true
local options={db=db,project='process-bench',revisions={policy='1',resources='1'},validate=function()return allowed,'fixture:current' end,
 qualification={id='fixture-production-adapter',revision='1',check=function(c,r) return qualified,'fixture:runtime-qualification' end}}
local r=assert(registry.open(options))
local function add(version)
 local c=fixture.candidate(false);c.source=c.source..'\n-- version '..version;c.source_hash=require('workflow').hash(c.source)
 assert(r:register('followup',version,c));return assert(r:evaluate('followup',version,fixture.dataset(false),fixture.policy()))
end
local first=add('1')
check(first.eligibility,'real evaluator passes')
check(first.coverage.production_runtime_qualified==false,'isolation label preserved')
check(not r:resolve('followup',{run_id='before'}),'storage never activates')
check(not r:register('followup','1',fixture.candidate(false)),'version immutable')
check(not r:activate('followup','1',first,{}),'CAS required')
qualified=false
check(not r:activate('followup','1',first,{expected_generation=0}),'runtime qualification required')
qualified=true
local win,err=r:activate('followup','1',first,{expected_generation=0});assert(win,require('json').encode(err))
check(win.generation==1 and win.action=='activate','default auto activates')
local pinned=assert(r:resolve('followup',{run_id='inflight'}))
local second=add('2')
local bad=require('json').decode(require('json').encode(second));bad.evidence_refs.dataset.revision='tampered'
check(not r:activate('followup','2',bad,{expected_generation=1}),'report table forgery rejected')
assert(r:control(nil,'review'))
check(assert(r:activate('followup','2',second,{expected_generation=1,mode='auto'})).action=='queued','project review restricts call auto')
assert(r:control('followup','off'))
check(assert(r:activate('followup','2',second,{expected_generation=1})).action=='off','workflow off restrictive')
check(r:head('followup').version=='1','controls preserve pointer')
assert(r:control(nil,'auto'));assert(r:control('followup','auto'))
assert(r:activate('followup','2',second,{expected_generation=1}))
check(r:resolve('followup',{run_id='inflight'}).version=='1','old pin stable')
check(r:resolve('followup',{run_id='new'}).version=='2','new run selects v2')
local loser,why=r:activate('followup','1',first,{expected_generation=1})
check(not loser and why.code=='activation_conflict','CAS loser recorded')
check(r:audit('followup')[#r:audit('followup')].action=='conflict','winner and loser audited')
local rb,why=r:rollback('followup','1',{expected_generation=2});assert(rb,require('json').encode(why))
check(r:resolve('followup',{run_id='new'}).version=='2','rollback preserves v2 run')
check(r:resolve('followup',{run_id='postrollback'}).version=='1','rollback new selection')
local reopened=assert(registry.open(options))
check(reopened:resolve('followup',{run_id='restart'}).version=='1','reopen durable pointer')
options.revisions.policy='2'
check(not reopened:resolve('followup',{run_id='stale'}),'revision changes reject stale evaluation')
options.revisions.policy='1';allowed=false
check(not reopened:resolve('followup',{run_id='revoked'}),'current authority enforced')
allowed=true
assert(r:activate('followup','2',second,{expected_generation=3,percent=50}))
local versions={}
for i=1,20 do versions[assert(r:resolve('followup',{run_id='stage'..i})).version]=true end
check(versions['1'] and versions['2'],'staged deterministic cohorts')
local cap=require('capability');local calls=0
assert(cap.register({id='bench.send',version='1',effect='write'},function(args)calls=calls+1;return {text='All done',recipient=args.recipient}end))
local auth=require('invoke').context{state={mode='auto',guards=false}}
local run=assert(r:start('followup',{run_id='real',authority=auth,context={call_1_args={recipient='fixture'}},defer=true}))
check(run:snapshot().workflow.version=='1' or run:snapshot().workflow.version=='2','actual run selected version')
local old=run:snapshot().workflow.version
assert(r:rollback('followup','1',{expected_generation=4}))
local result=run:resume()
check(result.status=='succeeded' and result.workflow.version==old and calls==1,'actual deferred run pinned across rollback')
local next_run=assert(r:start('followup',{run_id='actual-next',authority=auth,context={call_1_args={recipient='fixture'}},defer=true}))
check(next_run:snapshot().workflow.version=='1','actual new run rollback version')
allowed=false
check(next_run:resume().status=='denied' and calls==1,'current admission revoked before effects')
allowed=true
-- A real source run suspends inside a trusted provider, across activation.
local suspended=assert(r:start('followup',{run_id='suspended',authority=auth,context={call_1_args={revision='1',resolve=function()
 coroutine.yield('fixture pause');return {recipient='fixture'}
end}}}))
check(suspended:snapshot().status=='suspended' and suspended:snapshot().workflow.version=='1','actual provider suspension pins v1')
assert(r:activate('followup','2',second,{expected_generation=5}))
check(suspended:resume().status=='succeeded' and suspended:snapshot().workflow.version=='1','suspended source retains v1 after v2 activation')
local provider_calls=calls
local provider_run=assert(r:start('followup',{run_id='provider-revocation',authority=auth,context={call_1_args={revision='1',resolve=function(ctx)
 coroutine.yield('before provider effect');ctx:call('bench.send',{recipient='fixture'});return {recipient='fixture'}
end}}}))
check(provider_run:snapshot().status=='suspended','provider waiting before capability effect')
allowed=false
check(provider_run:resume().status=='denied' and calls==provider_calls,'provider dispatch admission rechecks revocation after suspension')
allowed=true
assert(r:rollback('followup','1',{expected_generation=6}))
check(suspended:snapshot().learning.run_id=='suspended','durable logical pin linked in actual run snapshot')
assert(r:set_state('followup','1','quarantined','fixture drift'))
check(not r:resolve('followup',{run_id='postrollback'}),'quarantine rejects pinned future execution')
-- The admission hook also follows ordinary composed/nested workflows.
local workflow=require('workflow')
assert(workflow.register{id='promotion-child',version='1',capabilities={['bench.send']='1'},run=function(ctx)
 ctx:yield('nested pause');return ctx:call('bench.send',{recipient='fixture'})
end})
assert(workflow.register{id='promotion-parent',version='1',workflows={['promotion-child']='1'},run=function(ctx)
 return ctx:workflow('promotion-child')
end})
local nested_allowed=true
local nested=assert(workflow.start('promotion-parent',{authority=auth,admit=function()return nested_allowed,{code='fixture_revoked'}end}))
local before_nested=calls
check(nested:snapshot().status=='suspended','nested workflow suspended')
nested_allowed=false
check(nested:resume().status=='denied' and calls==before_nested,'nested capability obeys current admission')
-- Finish a staged rollout without replacing its fallback or existing logical pins.
local third=add('3')
assert(r:activate('followup','3',third,{expected_generation=7,percent=20}))
local current=assert(r:rollout('followup',100,{expected_generation=8}))
check(current.action=='rollout' and current.generation==9,'rollout completion has CAS and audit')
check(r:resolve('followup',{run_id='rollout-complete'}).version=='3','finished rollout selects candidate for every new run')
check(not r:start('followup',{run_id='no-authority'}),'actual execution requires explicit current authority')
local count_before=calls
local narrowed=assert(r:start('followup',{run_id='additional-admission',authority=auth,context={call_1_args={recipient='fixture'}},admit=function()return false,{code='host_narrowed'}end}))
check(narrowed:snapshot().status=='denied' and calls==count_before,'caller admission restriction composes without widening')
for _,blocked in ipairs({'disabled','quarantined'})do
 local id='preserve-'..blocked
 local reports={}
 for _,version in ipairs({'1','2'})do
  assert(r:register(id,version,fixture.candidate(false)))
  reports[version]=assert(r:evaluate(id,version,fixture.dataset(false),fixture.policy()))
 end
 assert(r:activate(id,'1',reports['1'],{expected_generation=0}))
 assert(r:set_state(id,'1',blocked,'fixture block'))
 assert(r:activate(id,'2',reports['2'],{expected_generation=1,percent=50}))
 check(r:get(id,'1').state==blocked,'replacing pointer preserves '..blocked)
 check(not r:rollback(id,'1',{expected_generation=2}),'blocked prior head cannot rollback: '..blocked)
 assert(r:rollout(id,100,{expected_generation=2}))
 check(r:get(id,'1').state==blocked,'rollout preserves blocked fallback: '..blocked)
end
print('learning_promote: '..count..' checks passed')
