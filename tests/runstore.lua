local runstore=require('runstore')
local workflow,cap,invoke=require('workflow'),require('capability'),require('invoke')
local db=assert(require('db').open(os.tmpname()))
assert(require('evidence').configure{db=db})
assert(runstore.configure{db=db})
local authority=invoke.context{state={mode='auto',guards=false}}
local remote={message_count=0,operations={}}
assert(cap.register({id='durable.write',version='1',effect='write',revision='impl-1',
 reconcile=function(args,execution)
   return remote.operations[execution.operation_id],{status=remote.operations[execution.operation_id] and 'succeeded' or 'uncertain'}
 end},function(args,execution)
 remote.message_count=remote.message_count+1
 remote.operations[execution.operation_id]={text=args.text}
 coroutine.yield('ack_lost')
 return remote.operations[execution.operation_id]
end))
assert(cap.register({id='durable.next',version='1',effect='pure',revision='impl-1'},function(args)return args end))
local source=[[return function(ctx)
 local outputs={}
 for i=1,2 do
   outputs[i]=ctx:step('send',function()
     if i==1 then return ctx:call('durable.write',{text='hello'}).result end
     return ctx:call('durable.next',{text='done'}).result
   end)
 end
 return outputs
end]]
assert(workflow.register{id='durable.flow',version='1',source=source,durable='replay-v1',capabilities={['durable.write']='1',['durable.next']='1'}})
local h=assert(workflow.start('durable.flow',{authority=authority}))
assert(h:snapshot().status=='suspended')
local recovered=assert(runstore.resume(h:snapshot().id,{authority=authority}))
assert(recovered:snapshot().status=='succeeded')
assert(remote.message_count==1)
assert(recovered:snapshot().result[2].text=='done')
print('runstore: lost acknowledgement recovery passed')
local count=1
local function check(value,label) assert(value,label);count=count+1 end
local previous=h:resume()
check(previous.status=='failed' and previous.error.code=='run_ownership_lost','old handle is fenced')
check(remote.message_count==1,'old handle cannot repeat effects')
local _,terminal=runstore.resume(recovered:snapshot().id,{authority=authority})
check(terminal.code=='run_terminal','completed run does not rerun')
local _,noauth=runstore.resume('missing')
check(noauth.code=='current_authority_required','resume requires current authority')
local _,missing=runstore.resume('missing',{authority=authority})
check(missing.code=='workflow_non_resumable','unsupported resume clear')
local host,hosterr=workflow.register{id='durable.host',version='1',durable='replay-v1',run=function()end}
check(not host and hosterr.code=='workflow_non_resumable','closures not portable')
local denied=invoke.context{state={mode='auto',guards=false,tool_policy={['durable.write']='deny'}}}
local h2=assert(workflow.start('durable.flow',{authority=authority}))
local denied_resume=assert(runstore.resume(h2:snapshot().id,{authority=denied}))
check(denied_resume:snapshot().status~='succeeded' and remote.message_count==2,'revocation prevents reconciliation')
local unsupported=assert(workflow.register{id='durable.nondeterministic',version='1',durable='replay-v1',source=[[return function(ctx) pcall(os.time);return 1 end]]})
check(workflow.start(unsupported.id,{authority=authority}):snapshot().status=='failed','caught nondeterminism remains fatal')
local provider,provider_error=workflow.start('durable.flow',{authority=authority,context={value=function()return 1 end}})
check(not provider and provider_error.code=='checkpoint_unavailable','host context provider refused')
require('evidence').configure{secrets={'fixture-private'} }
local secret,secret_error=workflow.start('durable.flow',{authority=authority,context={value='fixture-private'}})
check(not secret and secret_error.code=='checkpoint_unavailable','redacted inputs not replayed')
local marker,marker_error=workflow.start('durable.flow',{authority=authority,context={value={evidence_marker='partial'}}})
check(not marker and marker_error.code=='checkpoint_unavailable','partial observations not replay values')
assert(workflow.register{id='durable.context',version='1',durable='replay-v1',capabilities={['durable.write']='1'},source=[[
return function(ctx)
 local selected=ctx:resolve('selected')
 return ctx:step(selected and 'yes' or 'no',function() return ctx:call('durable.write',{text='branch'}) end)
end]]})
local context_run=assert(workflow.start('durable.context',{authority=authority,context={selected=true}}))
local before=remote.message_count
assert(db:run('UPDATE durable_steps SET outcome=NULL WHERE run_id=? AND seq=1',{context_run:snapshot().id}))
local missing_result=assert(runstore.resume(context_run:snapshot().id,{authority=authority})):snapshot()
check(missing_result.error.code=='replay_result_missing' and remote.message_count==before,'missing observation stops replay')
-- Branch divergence is detected from persisted occurrence order before effects.
local branch=assert(workflow.start('durable.context',{authority=authority,context={selected=false}}))
local branch_id=branch:snapshot().id
assert(db:run('UPDATE durable_steps SET request=? WHERE run_id=? AND seq=2',{'["table",[]]',branch_id}))
local diverged=assert(runstore.resume(branch_id,{authority=authority})):snapshot()
check(diverged.error.code=='replay_diverged','changed recorded branch refused')
-- Cache reuse remains separate from fresh executions and is reauthorized.
local reads=0
local read=assert(cap.register({id='durable.read',version='1',effect='read',cache='result',revision='code-1',provider_revision='provider-1',source_revision='source-1'},function(args)
 reads=reads+1;return {answer=args.value},{usage={tokens=9}}
end))
local cache=runstore.cache
local deps={source='source-1',provider='provider-1'}
local freshness={ttl=60,revision='epoch-1'}
local outcome=cap.call(authority,read.id,read.version,{value=4})
assert(cache.store(read,{value=4},deps,freshness,outcome))
local hit=assert(cache.lookup(read,{value=4},deps,freshness,{authority=authority}))
check(hit.result.answer==4 and reads==1,'eligible read hit avoids provider')
check(next(hit.usage)==nil and hit.receipt.execution.historical_usage.tokens==9,'cache does not charge historical usage')
check(not cache.lookup(read,{value=5},deps,freshness,{authority=authority}),'cache keys inputs')
check(not cache.lookup(read,{value=4},{source='source-2',provider='provider-1'},freshness,{authority=authority}),'source revision invalidates')
check(not cache.lookup(read,{value=4},{source='source-1',provider='provider-2'},freshness,{authority=authority}),'provider revision invalidates')
local changed=cap.resolve(read.id,read.version);changed.revision='code-2'
check(not cache.lookup(changed,{value=4},deps,freshness,{authority=authority}),'code revision invalidates')
local cache_denied=invoke.context{state={mode='auto',guards=false,tool_policy={[read.id]='deny'}}}
check(not cache.lookup(read,{value=4},deps,freshness,{authority=cache_denied}),'cache current policy refusal')
assert(db:run('UPDATE durable_cache SET expires=0',{}))
check(not cache.lookup(read,{value=4},deps,freshness,{authority=authority}),'expired cache misses')
check(not cache.store(cap.resolve('durable.write','1'),{},deps,freshness,outcome),'writes ineligible')
check(not cache.lookup(read,{value=4},deps,freshness),'cache requires current authority')
-- Fresh starts still execute adapters and resolve the current concrete context.
local fresh=cap.call(authority,read.id,read.version,{value=4})
check(reads==2 and fresh.result.answer==4,'fresh read executes independently of cache')
-- Completed observations replay, but current policy can reject their reuse.
local replay_writes=0
assert(cap.register({id='durable.pause',version='1',effect='pure',revision='1',reconcile=function()return true end},function()coroutine.yield();return true end))
assert(cap.register({id='durable.once',version='1',effect='write',revision='1'},function()replay_writes=replay_writes+1;return false end))
assert(workflow.register{id='durable.recorded',version='1',durable='replay-v1',capabilities={['durable.once']='1',['durable.pause']='1'},source=[[
return function(ctx)
 local x=ctx:step('once',function()return ctx:call('durable.once',{}).result end)
 ctx:step('pause',function()ctx:call('durable.pause',{}) end)
 return x
end]]})
local recorded=assert(workflow.start('durable.recorded',{authority=authority}))
local replayed=assert(runstore.resume(recorded:snapshot().id,{authority=authority})):snapshot()
check(replayed.status=='succeeded' and replayed.result==false and replay_writes==1,'completed false result replayed')
check(replayed.invocations[1].reused=='resume' and next(replayed.invocations[1].usage)==nil,'replay usage historical')
print('runstore: '..count..' checks passed')
-- A separate process has no workflow registry or closure from the first process.
local uv=require('uv')
local database=os.tmpname()
local script=os.tmpname()..'.lua'
local function quote(s)return "'"..s:gsub("'","'\\''").."'" end
local shared=string.format([[
local db=assert(require('db').open(%q))
local runstore,cap,invoke=require('runstore'),require('capability'),require('invoke')
assert(runstore.configure{db=db});assert(require('evidence').configure{db=db})
local ledger=assert(require('quota').open(db,nil,{subjects={account='restart'}}))
local policy=assert(require('policy').compile{{id='restart-quota',revision=1,capabilities={allow={'*'}},limits={tokens=10},quotas={{id='tokens',metric='tokens',subject='account',limit=20,window_seconds=3600}}}})
local authority=invoke.context{state={mode='auto',guards=false},ledger=ledger,policy=policy}
assert(db:exec('CREATE TABLE IF NOT EXISTS fake_remote (operation_id TEXT PRIMARY KEY, body TEXT)'))
assert(cap.register({id='process.write',version='1',revision='one',effect='write',bounded={tokens=true},estimate=function()return {tokens=9}end,reconcile_bounded={tokens=true},reconcile_estimate=function()return {tokens=0}end,reconcile=function(args,execution)
 local row=db:query('SELECT body FROM fake_remote WHERE operation_id=?',{execution.operation_id})[1]
 return row and row.body,{status=row and 'succeeded' or 'uncertain',usage={tokens=0}}
end},function(args,execution)
 assert(db:run('INSERT INTO fake_remote(operation_id,body) VALUES(?,?)',{execution.operation_id,args.text}))
 coroutine.yield('lost_ack')
 error('original process unexpectedly resumed')
end))
assert(cap.register({id='process.next',version='1',revision='one',effect='pure',bounded={tokens=true},estimate=function()return {tokens=0}end},function(args)return args,{usage={tokens=0}} end))
]],database)
local function subprocess(body)
 local f=assert(io.open(script,'w'));f:write(shared,body);f:close()
 local command=quote(assert(uv.exepath()))..' --eval '..quote(script)..' 2>&1'
 local result=sys.exec(command,20)
 check(result.code==0,'subprocess: '..(result.out or '')..(result.err or ''))
 return result.out
end
subprocess([[
local source=[=[return function(ctx)
 local values={}
 for i=1,3 do
  values[i]=ctx:step('iteration',function()
   if i==1 then return ctx:call('process.write',{text='once'}).result end
   if i%2==0 then return ctx:call('process.next',{branch='even'}).result end
   return ctx:call('process.next',{branch='odd'}).result
  end)
 end
 return values
end]=]
assert(require('workflow').register{id='process.flow',version='1',source=source,durable='replay-v1',capabilities={['process.write']='1',['process.next']='1'}})
local h=assert(require('workflow').start('process.flow',{authority=authority}))
assert(h:snapshot().status=='suspended')
os.exit(0)
]])
subprocess([[
local id=db:query('SELECT id FROM durable_runs')[1].id
assert(not require('workflow').resolve('process.flow','1'))
local h=assert(runstore.resume(id,{authority=authority}))
local state=h:snapshot()
assert(state.status=='succeeded',require('json').encode(state.error))
assert(state.result[1]=='once' and state.result[2].branch=='even' and state.result[3].branch=='odd')
assert(#db:query('SELECT * FROM fake_remote')==1)
assert(db:query('SELECT used FROM quota_buckets')[1].used==9)
assert(#db:query("SELECT id FROM quota_reservations WHERE status='reserved'")==1)
assert(state.invocations[1].receipt.accounting_pending.settlement=='not_attempted')
print('separate process source recovery: one message, both branches reached')
]])
os.remove(script);os.remove(database)
-- Persist the run-local policy as well as the authority passed by the host.
local run_policy=assert(require('policy').compile{{id='durable-local',revision=1,capabilities={allow={'durable.once','durable.pause'}}}})
local localpolicy=assert(workflow.start('durable.recorded',{authority=authority,policy=run_policy}))
local resumed_policy=assert(runstore.resume(localpolicy:snapshot().id,{authority=authority})):snapshot()
check(resumed_policy.status=='succeeded','run policy reconstructs with current host authority')
-- Resume takeover during reconciliation fences a competing reconstructed handle.
local competing,entered
assert(cap.register({id='durable.race',version='1',revision='one',effect='write',reconcile=function()
 if not entered then entered=true;coroutine.yield('reconciling') end
 return 1
end},function()coroutine.yield();return 1 end))
local tails=0
assert(cap.register({id='durable.tail',version='1',revision='one',effect='write'},function()tails=tails+1;return 1 end))
assert(workflow.register{id='durable.racing',version='1',durable='replay-v1',capabilities={['durable.race']='1',['durable.tail']='1'},source=[[
return function(ctx)
 ctx:step('uncertain',function()ctx:call('durable.race',{})end)
 return ctx:step('tail',function()return ctx:call('durable.tail',{}).result end)
end]]})
local racing=assert(workflow.start('durable.racing',{authority=authority}))
local r1=assert(runstore.resume(racing:snapshot().id,{authority=authority}))
check(r1:snapshot().status=='suspended','first recovery suspended in reconciliation')
local r2=assert(runstore.resume(racing:snapshot().id,{authority=authority}))
check(r2:snapshot().status=='succeeded' and tails==1,'second recovery owns next effect')
local stale=r1:resume()
check(stale.status=='failed' and tails==1,'stale reconstruction cannot repeat tail')
print('runstore final: '..count..' checks passed')
for i,expression in ipairs({[[string.format('%p','x')]],[[('%p'):format('x')]],[[('x').dump(function()end)]],[[tostring({})]],[[math.random()]],[[coroutine.running()]]}) do
 local id='durable.nondeterminism.'..i
 assert(workflow.register{id=id,version='1',durable='replay-v1',source='return function()pcall(function() return '..expression..' end);return true end'})
 check(workflow.start(id,{authority=authority}):snapshot().status=='failed','nondeterminism blocked: '..expression)
end
assert(workflow.register{id='durable.format',version='1',durable='replay-v1',source=[[return function()return string.format('%s:%d','answer',42)end]]})
check(workflow.start('durable.format',{authority=authority}):snapshot().result=='answer:42','checked ordinary formatting retained')
-- Repeated context results use consistent value-copy semantics on both runs.
assert(workflow.register{id='durable.alias',version='1',durable='replay-v1',capabilities={['durable.pause']='1'},source=[[
return function(ctx)
 local a=ctx:resolve('record');local b=ctx:resolve('record')
 assert(a~=b);a.value=9;assert(b.value==1)
 ctx:step('pause',function()ctx:call('durable.pause',{})end)
 return b.value
end]]})
local alias=assert(workflow.start('durable.alias',{authority=authority,context={record={value=1}}}))
check(alias:snapshot().status=='suspended','first execution uses copied observations')
check(runstore.resume(alias:snapshot().id,{authority=authority}):snapshot().result==1,'replay copies preserve mutation behavior')
print('runstore deterministic: '..count..' checks passed')
-- Observation IDs are explicit captured inputs if Lua uses the return value.
assert(workflow.register{id='durable.observation',version='1',durable='replay-v1',capabilities={['durable.pause']='1'},source=[[
return function(ctx)
 local id=ctx:observe('branch',true)
 ctx:step(id,function()ctx:call('durable.pause',{})end)
 return id
end]]})
local observed=assert(workflow.start('durable.observation',{authority=authority}))
check(runstore.resume(observed:snapshot().id,{authority=authority}):snapshot().status=='succeeded','observation identifiers captured for replay')
-- Aliases to the raw string metatable retain the same source guard.
assert(workflow.register{id='durable.format.alias',version='1',durable='replay-v1',source=[[
return function()
 local raw=('').format
 local function helper()return raw('%p','x')end
 pcall(helper)
 return true
end]]})
check(workflow.start('durable.format.alias',{authority=authority}):snapshot().status=='failed','aliased raw formatter blocked')
-- Hook masks and outer budgets survive success, errors and suspended takeovers.
local hook_calls=0
local function host_hook()hook_calls=hook_calls+1 end
debug.sethook(host_hook,'cr',100000)
local formatted=assert(workflow.start('durable.format',{authority=authority})):snapshot()
local hook,mask,every=debug.gethook()
debug.sethook()
check(formatted.status=='succeeded' and hook==host_hook and mask=='cr' and every==100000 and hook_calls>0,'source hook composes and restores host hook')
assert(workflow.register{id='durable.budget',version='1',durable='replay-v1',source=[[return function()while true do pcall(function()local a=1+1 end)end end]]})
local bounded=assert(workflow.start('durable.budget',{authority=authority,instructions=20000})):snapshot()
check(bounded.status=='failed' and bounded.error.code=='workflow_budget','caught computation cannot starve budget')
local budgeted=assert(workflow.start('durable.recorded',{authority=authority,instructions=2000000}))
check(budgeted:snapshot().status=='suspended','bounded run reaches checkpoint')
local smaller=assert(runstore.resume(budgeted:snapshot().id,{authority=authority,instructions=1})):snapshot()
check(smaller.status=='failed','current smaller recovery budget enforced')
local cancelled=assert(workflow.start('durable.recorded',{authority=authority}));cancelled:cancel()
local _,cancel_error=runstore.resume(cancelled:snapshot().id,{authority=authority})
check(cancel_error.code=='run_terminal','cancelled run stays terminal')
local exhausted=assert(workflow.start('durable.flow',{authority=authority}))
assert(db:run('UPDATE durable_runs SET attempts=8 WHERE id=?',{exhausted:snapshot().id}))
local _,attempts=runstore.resume(exhausted:snapshot().id,{authority=authority})
check(attempts.code=='resume_limit','recovery attempts bounded')
print('runstore coverage: '..count..' checks passed')
-- Bounded cached providers have zero *new* provider spend under current quotas.
local ledger=assert(require('quota').open(db))
local quota_policy=assert(require('policy').compile{{id='durable.cache.quota',revision=1,capabilities={allow={'*'}},limits={tokens=10},quotas={{id='tokens',metric='tokens',limit=10,window_seconds=3600}}}})
local quota_authority=invoke.context{state={mode='auto',guards=false},ledger=ledger,policy=quota_policy}
local bounded_calls=0
local bounded_read=assert(cap.register({id='durable.bounded',version='1',effect='read',cache='result',revision='code',source_revision='source',provider_revision='provider',bounded={tokens=true},estimate=function()return {tokens=9}end},function()
 bounded_calls=bounded_calls+1;return 'read',{usage={tokens=9},artifacts={{uri='fixture:artifact'}}}
end))
local bounded_outcome=cap.call(quota_authority,bounded_read.id,bounded_read.version,{})
assert(cache.store(bounded_read,{},deps,freshness,bounded_outcome))
local bounded_hit=assert(cache.lookup(bounded_read,{},deps,freshness,{authority=quota_authority}))
check(bounded_hit.usage.tokens==0 and bounded_hit.receipt.execution.historical_usage.tokens==9 and bounded_calls==1,'bounded cache usage zero under quota')
check(bounded_hit.artifacts[1].uri=='fixture:artifact','cached artifacts retained')
local used=db:query('SELECT used FROM quota_buckets')[1].used
check(used==9,'cache does not double charge provider cost')
local custom_accounting=invoke.context{state={mode='auto',guards=false},ledger={reserve=function()end,settle=function()end}}
local cannot_restore,restore_error=workflow.start('durable.flow',{authority=custom_accounting})
check(not cannot_restore and restore_error.code=='workflow_non_resumable','unrecognized custom ledger recovery refused explicitly')
print('runstore accounting: '..count..' checks passed')
local policy_tails=tails
local narrow_policy=assert(require('policy').compile{{id='durable-no-tail',revision=1,capabilities={allow={'durable.pause'},deny={'durable.tail'}}}})
assert(workflow.register{id='durable.policy.tail',version='1',durable='replay-v1',capabilities={['durable.pause']='1',['durable.tail']='1'},source=[[
return function(ctx)
 ctx:step('pause',function()ctx:call('durable.pause',{})end)
 return ctx:step('tail',function()return ctx:call('durable.tail',{}).result end)
end]]})
local narrow=assert(workflow.start('durable.policy.tail',{authority=authority,policy=narrow_policy}))
check(narrow:snapshot().status=='suspended','narrow policy reaches permitted observation')
local still_narrow=assert(runstore.resume(narrow:snapshot().id,{authority=authority})):snapshot()
check(still_narrow.status~='succeeded' and tails==policy_tails,'run-local denial persists under permissive new authority')
local unknown_count=0
assert(cap.register({id='durable.unknown',version='1',revision='one',effect='write'},function()unknown_count=unknown_count+1;coroutine.yield()end))
assert(workflow.register{id='durable.unreconciled',version='1',durable='replay-v1',capabilities={['durable.unknown']='1'},source=[[return function(ctx)return ctx:step('unknown',function()return ctx:call('durable.unknown',{})end)end]]})
local unknown=assert(workflow.start('durable.unreconciled',{authority=authority}))
local unresolved=assert(runstore.resume(unknown:snapshot().id,{authority=authority})):snapshot()
check(unresolved.status=='uncertain' and unresolved.error.code=='reconciliation_uncertain' and unknown_count==1,'unknown write never retried without reconciliation')
print('runstore final coverage: '..count..' checks passed')
-- Native ledger identity persists across a new SQLite connection. The original
-- bounded effect reservation remains held; its status query spends zero tokens.
local quota_path=os.tmpname()
local qdb=assert(require('db').open(quota_path))
assert(runstore.configure{db=qdb});assert(require('evidence').configure{db=qdb})
local original_ledger=assert(require('quota').open(qdb,nil,{subjects={account='fixture-account'}}))
local recovery_policy=assert(require('policy').compile{{id='durable-recovery-quota',revision=1,capabilities={allow={'*'}},limits={tokens=10},quotas={{id='shared',metric='tokens',subject='account',limit=20,window_seconds=3600}}}})
local original_authority=invoke.context{state={mode='auto',guards=false},ledger=original_ledger,policy=recovery_policy}
local effects=0
local original_operation
assert(cap.register({id='quota.recover.write',version='1',revision='one',effect='write',bounded={tokens=true},estimate=function()return {tokens=9}end,
 reconcile_bounded={tokens=true},reconcile_estimate=function()return {tokens=0}end,
 reconcile=function(args,execution)
  assert(execution.operation_id==original_operation and execution.ceilings.tokens==0)
  return 'written',{usage={tokens=0}}
 end},function(args,execution)
 effects=effects+1;original_operation=execution.operation_id
 assert(execution.ceilings.tokens==9)
 coroutine.yield('lost')
 return 'written',{usage={tokens=9}}
end))
assert(cap.register({id='quota.recover.next',version='1',revision='one',effect='pure',bounded={tokens=true},estimate=function()return {tokens=0}end},function()return 'next',{usage={tokens=0}}end))
assert(workflow.register{id='quota.recover.flow',version='1',durable='replay-v1',capabilities={['quota.recover.write']='1',['quota.recover.next']='1'},source=[[
return function(ctx)
 ctx:step('write',function()return ctx:call('quota.recover.write',{}).result end)
 return ctx:step('next',function()return ctx:call('quota.recover.next',{}).result end)
end]]})
local quota_run=assert(workflow.start('quota.recover.flow',{authority=original_authority}))
check(quota_run:snapshot().status=='suspended','quota-governed durable write supported')
local resumed_db=assert(require('db').open(quota_path))
local new_ledger=assert(require('quota').open(resumed_db,nil,{subjects={account='fixture-account'}}))
check(require('quota').identity(new_ledger).id==require('quota').identity(original_ledger).id,'ledger identity stable after reopen')
local new_authority=invoke.context{state={mode='auto',guards=false},ledger=new_ledger,policy=recovery_policy}
assert(runstore.configure{db=resumed_db});assert(require('evidence').configure{db=resumed_db})
local quota_recovered=assert(runstore.resume(quota_run:snapshot().id,{authority=new_authority})):snapshot()
check(quota_recovered.status=='succeeded' and quota_recovered.result=='next' and effects==1,'standard quota recovery advances without duplicate effect')
local original_reservation=resumed_db:query('SELECT status FROM quota_reservations WHERE id=?',{original_operation})[1]
check(original_reservation and original_reservation.status=='reserved','original reservation not fabricated as settled')
check(resumed_db:query('SELECT used FROM quota_buckets')[1].used==9,'query and continuation do not double charge original provider spend')
local pending=quota_recovered.invocations[1].receipt.accounting_pending
check(pending.reservation_id==original_operation and pending.settlement=='not_attempted','unresolved original accounting explicitly referenced')
local other_ledger=assert(require('quota').open(assert(require('db').open(os.tmpname())),nil,{subjects={account='fixture-account'}}))
local new_run=assert(workflow.start('quota.recover.flow',{authority=original_authority}))
local wrong_authority=invoke.context{state={mode='auto',guards=false},ledger=other_ledger,policy=recovery_policy}
local wrong,wrong_error=runstore.resume(new_run:snapshot().id,{authority=wrong_authority})
check(not wrong and wrong_error.code=='recovery_failed','different persistent ledger refused')
local wrong_subject_ledger=assert(require('quota').open(resumed_db,nil,{subjects={account='different-account'}}))
local subject_authority=invoke.context{state={mode='auto',guards=false},ledger=wrong_subject_ledger,policy=recovery_policy}
local wrong_subject=runstore.resume(new_run:snapshot().id,{authority=subject_authority})
check(not wrong_subject,'different current subject binding refused')
local identity=require('quota').identity(new_ledger);identity.id='forged'
check(require('quota').identity(new_ledger).id~='forged' and require('quota').identity({identity=function()return identity end})==nil,'ledger identity recognition remains module-private')
print('runstore standard ledger: '..count..' checks passed')
-- Review regression: nil holes must not hide identity-bearing format arguments.
for i,expression in ipairs({
 [[string.format('%s %s',nil,{})]],
 [[string.format('%s %s',nil,function()end)]],
 [[string.format('%s %s %s','prefix',nil,{})]],
 [[string.format('%s %s %s %s',nil,'middle',nil,function()end)]],
}) do
 local id='durable.format.nil.'..i
 assert(workflow.register{id=id,version='1',durable='replay-v1',source='return function()pcall(function()return '..expression..' end);return true end'})
 check(workflow.start(id,{authority=authority}):snapshot().status=='failed','format rejects opaque vararg after nil: '..expression)
end
assert(workflow.register{id='durable.format.nil.scalar',version='1',durable='replay-v1',source=[[return function()return string.format('%s %s %s',nil,'middle',nil)end]]})
check(workflow.start('durable.format.nil.scalar',{authority=authority}):snapshot().result=='nil middle nil','scalar nil formatting retained')

-- Review regression: identical aggregate dependency sets do not permit moving a
-- version between the root and an unused declared child after registry restart.
local original_workflow=package.loaded.workflow
local function fresh_registry()
 package.loaded.workflow=nil
 return require('workflow')
end
local binding_effects={}
for _,version in ipairs({'1','2'}) do
 assert(cap.register({id='binding.write',version=version,revision=version,effect='write'},function()
  binding_effects[#binding_effects+1]=version;return version
 end))
end
local binding_source=[[return function(ctx)
 ctx:step('pause',function()ctx:call('durable.pause',{})end)
 return ctx:step('write',function()return ctx:call('binding.write',{}).result end)
end]]
local unused_source=[[return function()return true end]]
local function register_bindings(w,root_version,child_version,durable)
 assert(w.register{id='binding.child',version='1',source=unused_source,durable='replay-v1',capabilities={['binding.write']=child_version}})
 assert(w.register{id='binding.root',version='1',source=binding_source,durable=durable,capabilities={['durable.pause']='1',['binding.write']=root_version},workflows={['binding.child']='1'}})
end
local before_registry=fresh_registry()
register_bindings(before_registry,'1','2','replay-v1')
local binding_run=assert(before_registry.start('binding.root',{authority=authority}))
check(binding_run:snapshot().status=='suspended','binding fixture reaches durable frontier')
local changed_registry=fresh_registry()
register_bindings(changed_registry,'2','1','replay-v1')
local changed_run,binding_error=runstore.resume(binding_run:snapshot().id,{authority=authority})
check(not changed_run and binding_error.code=='dependency_changed' and #binding_effects==0,'swapped per-workflow capability pins refused before effect')
-- The durable contract itself is part of the executable registration identity.
local changed_contract=fresh_registry()
register_bindings(changed_contract,'1','2',nil)
local contract_run,contract_error=runstore.resume(binding_run:snapshot().id,{authority=authority})
check(not contract_run and contract_error.code=='dependency_changed','changed durable contract refused')

-- Swap dependency edges while retaining root, holder, and both child versions in
-- the aggregate set. Root source and every child source remain byte-identical.
local edge_source=[[return function(ctx)
 ctx:step('pause',function()ctx:call('durable.pause',{})end)
 return ctx:workflow('edge.child')
end]]
local child_source=[[return function(ctx)return ctx:step('write',function()return ctx:call('binding.write',{}).result end)end]]
local function register_edges(w,root_child,holder_child)
 for _,version in ipairs({'1','2'}) do
  assert(w.register{id='edge.child',version=version,source=child_source,durable='replay-v1',capabilities={['binding.write']=version}})
 end
 assert(w.register{id='edge.holder',version='1',source=unused_source,durable='replay-v1',workflows={['edge.child']=holder_child}})
 assert(w.register{id='edge.root',version='1',source=edge_source,durable='replay-v1',capabilities={['durable.pause']='1'},workflows={['edge.child']=root_child,['edge.holder']='1'}})
end
local before_edges=fresh_registry();register_edges(before_edges,'1','2')
local edge_run=assert(before_edges.start('edge.root',{authority=authority}))
check(edge_run:snapshot().status=='suspended','edge fixture reaches durable frontier')
local after_edges=fresh_registry();register_edges(after_edges,'2','1')
local changed_edge,edge_error=runstore.resume(edge_run:snapshot().id,{authority=authority})
check(not changed_edge and edge_error.code=='dependency_changed' and #binding_effects==0,'changed workflow dependency edges refused before effect')
-- An unchanged re-registration remains a usable reconstruction path.
local identical=fresh_registry();register_edges(identical,'1','2')
local unchanged=assert(runstore.resume(edge_run:snapshot().id,{authority=authority})):snapshot()
check(unchanged.status=='succeeded' and unchanged.result=='1' and #binding_effects==1,'exact original per-workflow bindings still recover')
package.loaded.workflow=original_workflow
print('runstore reviewed pins and varargs: '..count..' checks passed')
