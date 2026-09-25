package.path='lua/?.lua;lua/?/init.lua;'..package.path
local monitor=require('learning.monitor')
local db=assert(require('db').open(os.tmpname()))
assert(require('evidence').configure{db=db})
local fixture=dofile('tests/fixtures/process_bench/followup.lua')
local registry=assert(require('learning.registry').open{db=db,project='process-bench',validate=function()return true,'fixture:authority'end,qualification={id='fixture',revision='1',check=function()return true,'fixture:runtime'end}})
for _,v in ipairs({'1','2','3'})do
 assert(registry:register('followup',v,fixture.candidate(false)))
 local report=assert(registry:evaluate('followup',v,fixture.dataset(false),fixture.policy()))
 if v~='3'then assert(registry:activate('followup',v,report,{expected_generation=tonumber(v)-1}))end
end
local count=0
local function check(v,m)assert(v,m);count=count+1 end
local calls,good,wait,stale=0,true,false,false
assert(require('capability').register({id='bench.send',version='1',effect='write'},function(args)
 calls=calls+1;if wait then coroutine.yield('pending')end;return {recipient=args.recipient,text=good and 'All done' or 'Wrong'}
end))
local auth=require('invoke').context{ledger=assert(require('quota').open(db)),state={mode='auto',guards=false}}
local assessed=0
local function assess(s)
 assessed=assessed+1
 return {variant='recipient',verifier={passed=s.result and s.result.text=='All done' or false,ref='fixture:independent-check:'..s.id},dependencies={current=not stale,ref='fixture:current-schema'},cost={value=1,unit='units'},latency_ms=assessed==1 and 100000 or 1}
end
local function open()return assert(monitor.open{db=db,project='process-bench',registry=registry,assess=assess,policy={cost_unit='units'}})end
local m=open()
local serial=0
local function start(options)
 serial=serial+1;options=options or {};options.authority=auth;options.run_id='monitor-'..serial;options.context={call_1_args={recipient='current-person'}}
 local h,e=registry:start('followup',options);assert(h,require('json').encode(e));return h
end
local first=start():snapshot()
check(first.status=='succeeded' and first.monitoring.health.latest.n==1,'actual terminal observation')
check(first.monitoring.health.samples[1].classification=='verified','independent host verification')
check(registry:get('followup','2').state=='active','one latency outlier keeps active')
wait=true;local suspended=start();check(suspended:snapshot().status=='suspended' and assessed==1,'no premature observation')
wait=false;suspended:resume();check(assessed==2,'eventual terminal observed once');suspended:resume();check(assessed==2,'resume idempotent')
local cancelled=start{defer=true};cancelled:cancel();check(assessed==3,'cancellation observed');cancelled:cancel();check(assessed==3,'cancel idempotent')
good=false
local failures={}
for i=1,4 do failures[i]=start():snapshot()end
check(registry:get('followup','2').state=='quarantined','actual failures quarantine promoted version')
check(failures[#failures].monitoring.quarantined,'quarantine action visible')
local before=calls;check(not registry:start('followup',{authority=auth,run_id='blocked'}),'new admission blocked');check(calls==before,'no hidden effect retry')
m=open();check(m:observe(failures[1]).duplicate,'restart duplicates not counted')
local health=assert(m:explain('followup')).versions[1]
check(health.total==7 and #health.samples==7,'durable bounded sample count')
check(health.latest.failure_lower>=.2 and health.samples[4].remine=='failure_or_unknown','inspectable confidence and failed provenance')
check(health.samples[4].source_ref==failures[1].id,'source linked for remining')
assert(registry:rollback('followup','1',{expected_generation=2}))
good=true;check(start():snapshot().status=='succeeded','healthy rollback usable')
local r3=registry:get('followup','3');assert(registry:activate('followup','3',r3.report,{expected_generation=3}))
stale=true;start();check(registry:get('followup','3').state=='quarantined','changed schema quarantines immediately')
check(not registry:activate('followup','2',registry:get('followup','2').report,{expected_generation=4}),'quarantine monotone')
print('learning_monitor: '..count..' checks passed')
-- Terminal observer exceptions cannot rewrite successful application effects.
assert(registry:rollback('followup','1',{expected_generation=4}))
stale=false
local observed_after=0
start{on_terminal=function()observed_after=observed_after+1;error('host observer failed')end}
check(observed_after==1,'existing terminal observer composed')
local capacity=assert(monitor.open{db=db,project='process-bench',registry=registry,assess=assess,policy={max_runs=1}})
local unavailable,why=registry:start('followup',{authority=auth,run_id='capacity-refused'})
check(not unavailable and why.code=='monitor_capacity_exhausted','bounded receipts fail closed rather than forget duplicate identities')
m=open()
assert(db:exec([[CREATE TRIGGER monitor_test_outage BEFORE INSERT ON learning_health_seen BEGIN SELECT RAISE(ABORT,'test outage'); END;]]))
local lost=start():snapshot()
check(lost.status=='succeeded' and lost.monitoring.error,'monitor storage failure preserves successful actual outcome')
assert(db:exec('DROP TRIGGER monitor_test_outage'))
m=open()
local blocked,block_reason=registry:start('followup',{authority=auth,run_id='restart-gap'})
check(not blocked and block_reason.code=='monitor_recovery_required','restart refuses unresolved terminal evidence gap')
check(#m:explain('followup').pending==1,'pending evidence gap inspectable')
assert(m:observe(lost))
check(#m:explain('followup').pending==0,'actual terminal snapshot resolves durable gap')
check(start():snapshot().status=='succeeded','reconciled restart admits current work')
local unknown=assert(monitor.open{db=db,project='process-bench',registry=registry,assess=function()error('missing verifier')end,policy={window=3,unknown_rate=.2}})
for i=1,3 do start()end
local unknown_health=assert(unknown:explain('followup')).versions
local found
for _,h in ipairs(unknown_health)do if h.version=='1'then found=h end end
check(found.latest.unknown==3 and found.latest.verified==0 and found.quarantine=='unknown_outcomes','unknown assessment cannot fabricate success')
check(#found.samples==3 and found.total>3,'bounded health window preserves lifetime count')
print('learning_monitor final: '..count..' checks passed')
-- Exact cap reserves the last slot for its owner, and groups are refused before effects.
local bounded_db=assert(require('db').open(os.tmpname()))
local bounded_registry=assert(require('learning.registry').open{db=bounded_db,project='bounded-monitor',validate=function()return true,'fixture:authority'end,qualification={id='fixture',revision='1',check=function()return true,'fixture:runtime'end}})
local bounded_monitor=assert(monitor.open{db=bounded_db,project='bounded-monitor',registry=bounded_registry,assess=assess,policy={max_runs=1,max_groups=1}})
assert(bounded_monitor:begin('one','1','reserved'))
check(bounded_monitor:admit('one','1','reserved'),'last reserved slot permits own effect admission')
local full,e=bounded_monitor:begin('two','1','another')
check(not full and e.code=='monitor_capacity_exhausted','reservation capacity enforced')
assert(bounded_monitor:abort('one','1','reserved'))
local group_monitor=assert(monitor.open{db=bounded_db,project='bounded-monitor',registry=bounded_registry,assess=assess,policy={max_runs=10,max_groups=1}})
assert(group_monitor:begin('one','1','group-one'))
local new_group,group_error=group_monitor:begin('two','1','group-two')
check(not new_group and group_error.code=='monitor_capacity_exhausted','group capacity counts live reservations before effects')
print('learning_monitor final: '..count..' checks passed')
-- A pending-only project has no health rows on which per-version guards can rely.
assert(require('evidence').configure{db=bounded_db})
assert(require('evidence_retention').configure{db=bounded_db})
assert(require('evidence_retention').delete_scope('bounded-monitor'))
local pending_explanation=group_monitor:explain('one')
check(not pending_explanation,'deleted pending-only scope cannot expose pending identities')
local missing_explanation=group_monitor:explain('nonexistent')
check(not missing_explanation,'nonexistent workflow cannot bypass deleted scope guard')
print('learning_monitor final: '..count..' checks passed')

-- BRAIN-35 monitored learned replay-v1 restart resolves the original receipt.
local trigger_fixture=dofile('tests/fixtures/workflow_triggers.lua')
local trigger_path=os.tmpname()
local first_host=trigger_fixture.open{path=trigger_path,interrupt=true,monitor=true}
local pending=assert(first_host.coordinator:run('fixture','timer','monitored-recovery'))
check(pending:snapshot().status=='suspended' and first_host.count()==1,'monitored learned occurrence interrupted after synthetic effect')
local next_host=trigger_fixture.open{path=trigger_path,monitor=true}
local resumed,resume_error=next_host.coordinator:recover('fixture','monitored-recovery',next_host.proof)
assert(resumed,resume_error and resume_error.code)
local resumed_snapshot=resumed:snapshot()
check(resumed_snapshot.status=='succeeded' and next_host.count()==1,'monitored restart reconciles one physical effect')
check(resumed_snapshot.monitoring and resumed_snapshot.monitoring.health.latest.n==1,'recovered terminal invokes current monitor observer once')
check(next_host.db:query('SELECT COUNT(*) AS n FROM learning_health_pending')[1].n==0,'recovery completes original monitor receipt')
assert(next_host.monitor:begin('followup','1','stale-proof'))
local ticket=assert(next_host.monitor:recovery_ticket('followup','1','stale-proof'))
local proof={owner=ticket.owner,ref='fixture:stopped-owner:'..ticket.owner,project=ticket.project,id=ticket.id,version=ticket.version,run_id=ticket.run_id}
assert(next_host.monitor:recover('followup','1','stale-proof',proof))
local stolen,stale_error=next_host.monitor:recover('followup','1','stale-proof',proof)
check(not stolen and stale_error.code=='monitor_recovery_owner_changed','stale exact-owner proof cannot steal recovered monitor receipt')
print('learning_monitor BRAIN-35: '..count..' checks passed')
