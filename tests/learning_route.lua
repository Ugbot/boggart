package.path='lua/?.lua;lua/?/init.lua;'..package.path
local route=require('learning.route')
local count=0
local function check(v,m)assert(v,m);count=count+1 end
local fixture=dofile('tests/fixtures/process_bench/followup.lua')
local db=assert(require('db').open(os.tmpname()))
local allowed=true
local registry=assert(require('learning.registry').open{db=db,project='process-bench',validate=function()return allowed,'fixture:authority'end,
 qualification={id='fixture',revision='1',check=function()return true,'fixture:runtime'end}})
assert(registry:register('followup','1',fixture.candidate(false)))
local report=assert(registry:evaluate('followup','1',fixture.dataset(false),fixture.policy()))
assert(registry:activate('followup','1',report,{expected_generation=0}))
local cap=require('capability');local calls,plans=0,0
local uncertain=false
assert(cap.register({id='bench.send',version='1',effect='write'},function(args)calls=calls+1;if uncertain then return nil,{status='uncertain',error={code='fixture_timeout'}}end;return {recipient=args.recipient,text='All done'}end))
assert(cap.register({id='route.plan',version='1',effect='read',bounded={tokens=true},estimate=function()return {tokens=10}end},function(args)
 plans=plans+1;check(args.request~=nil and args.reason~=nil,'planning gets current request/reason');return {planned=args.request,context=args.context},{usage={tokens=10}}
end))
local ledger=assert(require('quota').open(db))
local auth=require('invoke').context{ledger=ledger,state={mode='auto',guards=false}}
local entry={id='followup',scope='process-bench',terms={'chase','replies','follow up'},required={'call_1_args'},applicability=function(request,binding)
 local args=binding.call_1_args
 return not request:find('delete',1,true) and (type(args)=='function' or type(args)=='table' and (type(args.resolve)=='function' or args.recipient=='current-person')),'fixture:applicability'
end}
local policy={ledger=ledger,project='process-bench',registry=registry,authority=auth,catalog={entry},planning={capability='route.plan',version='1',max_tokens=30}}
local current={call_1_args={recipient='current-person'}}
local selected=route.select('Please chase the missing replies',current,policy)
check(selected.binding.call_1_args.recipient=='current-person','paraphrase binds current recipient')
check(selected.version=='1','registry selection pins version')
current.call_1_args.recipient='mutated';selected.binding.call_1_args.recipient='tampered'
local handle=assert(route.execute(selected))
check(handle:snapshot().status=='succeeded' and handle:snapshot().result.text=='All done' and calls==1,'private current binding resists mutation')
check(not route.execute(selected),'single decision never dispatches twice')
current.call_1_args.recipient='current-person'
local h,s=route.run('Please delete the missing replies',current,policy)
check(s.fallback and h:snapshot().status=='succeeded' and plans==1 and calls==1,'different intent runs explicit Lua planning')
check(h:snapshot().steps[1].site=='model_planning' or #h:snapshot().steps==1,'fallback is real workflow step')
local missing=route.select('chase replies',{},policy)
check(missing.fallback and missing.evidence.alternatives[1].reason=='missing_context','missing values never use history')
local mh=assert(route.execute(missing));check(mh:snapshot().status=='succeeded' and calls==1,'missing context only plans')
policy.catalog={entry,entry}
check(route.select('chase replies',current,policy).reason=='ambiguous','ambiguity refuses arbitrary top hit')
policy.catalog={entry};entry.scope='elsewhere'
check(route.select('chase replies',current,policy).evidence.alternatives[1].reason=='wrong_scope','scope isolation')
entry.scope='process-bench'
allowed=false
local denied=route.select('chase replies',current,policy)
check(denied.terminal and not route.execute(denied) and plans==2,'admission denial cannot retry via planner')
allowed=true
local fresh=route.select('chase replies',current,policy);allowed=false
local revoked=route.execute(fresh)
check(not revoked and calls==1,'current authority rechecked at execution')
allowed=true
local supplied=0
local ph=assert(route.run('chase replies',{call_1_args={revision='current',resolve=function()supplied=supplied+1;return {recipient='current-person'}end}},policy))
check(ph:snapshot().status=='succeeded' and supplied==1 and calls==2,'current provider executes through workflow resolver')
local bad=assert(route.run('chase replies',{call_1_args=function()return {recipient='historic-person'}end},policy))
check(bad:snapshot().status~='succeeded' and calls==2,'resolved provider applicability rechecked before learned effect')
local old=entry.applicability;entry.applicability=function()while true do end end
check(route.select('chase replies',current,policy).fallback,'expensive judgment bounded')
entry.applicability=old
local many={};for i=1,33 do many[i]=entry end;policy.catalog=many
check(route.select('chase replies',current,policy).reason=='retrieval_budget','catalog bounded before scan');policy.catalog={entry}
local searched=false
policy.memory={search=function(_,query,opts)searched=opts.scope=='process-bench' and opts.limit==32;return {backend='local',coverage={complete=false},hits={{scope='elsewhere',source_ref='ref'}},provenance={}}end}
check(route.select('no lexical match',current,policy).fallback and searched,'scoped memory does not import foreign hits');policy.memory=nil
-- Real ordinary request hook, source loaded before parent refreshes embedded modules.
package.loaded.skillrouter=dofile('lua/skillrouter.lua');package.loaded.route=dofile('lua/route.lua')
local api=dofile('lua/api.lua')
local sess={id='route-fixture',messages={},usage={},learning=policy}
local msg,status=api.run_on(sess,'Please chase replies',nil,{context=current,stream=function()error('ordinary model must not run')end})
check(status=='succeeded' and calls==3 and msg.content[1].text:find('All done',1,true),'ordinary request automatically uses learned workflow')
local msg2,status2=api.run_on(sess,'Please delete replies',nil,{context=current,stream=function()error('ordinary model must not run')end})
check(status2=='succeeded' and plans==3 and msg2.content[1].text:find('learning fallback',1,true),'ordinary fallback visible and budgeted Lua call')
-- Public selection fields cannot change the private dispatch decision.
local locked=route.select('chase replies',current,policy)
locked.workflow='unrelated';locked.version='hacked'
check(assert(route.execute(locked)):snapshot().status=='succeeded','selection cannot retarget private pin')
allowed=false
local blocked=route.select('chase replies',current,policy);blocked.terminal=false;blocked.reason='forged'
local before=plans
check(not route.execute(blocked) and plans==before,'selection cannot clear terminal refusal');allowed=true
local prior=entry.applicability
local attempted
entry.applicability=function()
 attempted=cap.call(auth,'bench.send','1',{recipient='forbidden'})
 return true,'fixture:effect-attempt'
end
local before_calls=calls
route.select('chase replies',current,policy)
check(attempted.receipt.dispatched==false and attempted.error.code=='permission_error' and calls==before_calls,'judgment cannot dispatch ordinary capability effects')
entry.applicability=prior
local envelope={request='context-request',reason='context-reason',max_tokens='context-limit',current='context-current'}
local eh=assert(route.run('unknown task',envelope,policy));local ev=eh:snapshot().result
check(ev.planned=='unknown task' and ev.context.request=='context-request' and ev.context.current=='context-current','planning envelope avoids injected key collisions')
local narrowed=require('invoke').context{state={mode='auto',guards=false,tool_policy={['bench.send']='deny'}},ledger=ledger}
policy.authority=narrowed
local deny_handle=assert(route.run('chase replies',current,policy))
check(deny_handle:snapshot().status~='succeeded' and calls==before_calls,'high similarity never overrides invocation policy')
policy.authority=auth
-- Two current providers must be judged together after each resolves.
entry.required={'call_1_args','other'}
entry.applicability=function(_,b)
 if type(b.other)=='function' or type(b.call_1_args)=='function' then return true,'fixture:pending' end
 local a=b.call_1_args
 return type(a)=='table' and a.recipient==b.other,'fixture:pair'
end
local pair=route.select('chase replies',{call_1_args=function(ctx)ctx:resolve('other');return {recipient='mismatch'}end,other=function()return 'expected'end},policy)
local pair_handle=assert(route.execute(pair))
check(pair_handle:snapshot().status~='succeeded' and calls==before_calls,'provider resolutions accumulate before applicability check')
entry.required={'call_1_args'};entry.applicability=prior
local config_pin=route.select('chase replies',current,policy)
local saved_registry=policy.registry
policy.registry={start=function()error('retargeted registry')end};policy.project='wrong-project'
check(assert(route.execute(config_pin)):snapshot().status=='succeeded','selected registry/project identity cannot be mutated')
policy.registry=saved_registry;policy.project='process-bench'
local old_limit=policy.planning.max_tokens;policy.planning.max_tokens=1
local budget_before=plans
local budget_handle=assert(route.run('unknown budget task',{},policy))
check(budget_handle:snapshot().status~='succeeded' and plans==budget_before,'planning token budget denies before dispatch')
policy.planning.max_tokens=old_limit
local original_terms=entry.terms;entry.terms={};entry.source_ref='fixture:learned'
policy.memory={search=function(_,query,opts)return {backend='local',coverage={complete=false},hits={{scope=opts.scope,source_ref='fixture:learned'}},provenance={{source_ref='fixture:learned'}}}end}
check(route.select('different words',current,policy).workflow=='followup','scoped memory retrieves catalog procedure by retained source reference')
entry.terms=original_terms;policy.memory=nil
-- A shared metatable-bearing provider is caller-owned, including its resolver.
local provider_resolves=0
local original_resolve=function()provider_resolves=provider_resolves+1;return {recipient='current-person'}end
local shared_provider=setmetatable({resolve=original_resolve,revision='shared-v1',cache='run',cache_key=function()return 'key'end},{__index={label='host-provider'}})
local first_guard_live=true
entry.applicability=function(_,b)
 return first_guard_live and (type(b.call_1_args.resolve)=='function' or b.call_1_args.recipient=='current-person'),'fixture:first-provider-guard'
end
local first_provider_run=assert(route.run('chase replies',{call_1_args=shared_provider},policy))
check(first_provider_run:snapshot().status=='succeeded','metatable provider resolves in first request')
local provider_provenance=first_provider_run:snapshot().resolutions[1].provenance
check(provider_provenance.provider_revision=='shared-v1' and provider_provenance.cache_lifetime=='run','provider wrapper preserves runtime revision and cache metadata')
check(shared_provider.resolve==original_resolve,'routing never mutates caller-owned metatable provider resolver')
first_guard_live=false;entry.applicability=prior
local second_provider_run=assert(route.run('chase replies',{call_1_args=shared_provider},policy))
check(second_provider_run:snapshot().status=='succeeded' and provider_resolves==2,'shared provider does not inherit earlier request guard')
check(shared_provider.resolve==original_resolve and shared_provider.revision=='shared-v1' and shared_provider.cache=='run','shared provider metadata and resolver remain unchanged')
uncertain=true
local plan_count=plans
local unknown=assert(route.run('chase replies',current,policy))
check(unknown:snapshot().status=='uncertain' and plans==plan_count,'uncertain dispatched effects never trigger planning retry')
print('learning_route: '..count..' checks passed')
