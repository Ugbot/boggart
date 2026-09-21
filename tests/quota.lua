local quota = require 'quota'
local policy = require 'policy'
local db = require 'db'
local passed=0
local function check(v,name) assert(v,name); passed=passed+1 end
local function refuse(value,err,code)
  check(value==nil and type(err)=='table' and err.code==code,'refusal '..code)
  return err
end
local function reserve_error(ledger,compiled,id,estimate,code)
  local r,e=ledger:reserve(compiled,id,estimate)
  return refuse(r,e,code)
end
local function compile(id,limit,metric,revision,window,subject)
  return assert(policy.compile{{id=id,revision=revision or 1,quotas={
    {id='budget',metric=metric or 'calls',limit=limit,window_seconds=window or 60,subject=subject}}}})
end
local path=os.tmpname()
local now=10
local a=assert(db.open(path))
local b=assert(db.open(path))
assert(a:exec('PRAGMA busy_timeout=0'))
assert(b:exec('PRAGMA busy_timeout=0'))
local la=assert(quota.open(a,function() return now end))
local lb=assert(quota.open(b,function() return now end))
local one=compile('shared',1)
-- Real overlapping SQLite write-lock lifetimes, not a serial race claim.
assert(a:exec('BEGIN IMMEDIATE'))
local locked=reserve_error(lb,one,'locked',{},'database')
check(locked.retryable,'live writer lock yields retryable refusal')
assert(a:exec('ROLLBACK'))
check(la:reserve(one,'first',{}),'first independent connection wins last token')
reserve_error(lb,one,'second',{},'exhausted')
check(lb:reserve(one,'first',{}).replayed,'reservation retry across connections')
reserve_error(lb,one,'first',{tokens=1},'conflict')
a:close()
a=assert(db.open(path))
la=assert(quota.open(a,function() return now end))
reserve_error(la,one,'restart',{},'exhausted')
reserve_error(la,compile('shared',1,'calls',2),'revision',{},'exhausted')
reserve_error(la,compile('shared',1,'calls',3,30),'shape',{},'rule_changed')
now=65
check(la:reserve(one,'new-window',{}),'fixed window replenishes')
now=1
reserve_error(lb,one,'backward',{},'exhausted')

local multi=assert(policy.compile{
 {id='atomic-a',revision=1,quotas={{id='q',metric='calls',limit=1,window_seconds=60}}},
 {id='atomic-z',revision=1,quotas={{id='q',metric='calls',limit=0,window_seconds=60}}},
})
reserve_error(la,multi,'multi',{},'exhausted')
local only=assert(policy.compile{{id='atomic-a',revision=1,quotas={{id='q',metric='calls',limit=1,window_seconds=60}}}})
check(la:reserve(only,'after-rollback',{}),'later bucket failure rolled back earlier bucket')

local cost=assert(policy.compile{{id='cost',revision=1,quotas={
 {id='attempts',metric='calls',limit=3,window_seconds=60},
 {id='tokens',metric='tokens',limit=10,window_seconds=60}}}})
reserve_error(la,cost,'missing',{},'invalid')
check(la:reserve(cost,'cost-1',{tokens=8}),'cost reserved before dispatch')
local settled=assert(la:settle('cost-1',{tokens=3},'failure'))
check(settled.status=='settled' and not settled.overrun,'failure reconciles known cost')
check(lb:settle('cost-1',{tokens=0},'success').replayed,'settlement is idempotent first result wins')
check(la:reserve(cost,'cost-1',{tokens=8}).status=='settled','settled reservation replay explicit')
check(lb:reserve(cost,'cost-2',{tokens=7}),'only unused cost refunded')
reserve_error(lb,cost,'cost-3',{tokens=1},'exhausted')
check(lb:settle('cost-2',nil,'uncertain'),'unknown cost retains reservation')
reserve_error(lb,cost,'cost-3',{tokens=1},'exhausted')
check(lb:reserve(cost,'cost-3',{tokens=0}),'third attempt consumes last count')
assert(lb:settle('cost-3',{tokens=0},'failure'))
reserve_error(lb,cost,'cost-4',{tokens=0},'exhausted')

-- Late refunds go to the original window, never the current window.
local late=compile('late',10,'tokens')
check(la:reserve(late,'late-old',{tokens=10}),'old cost window reserved')
now=130
check(la:reserve(late,'late-new',{tokens=10}),'new cost window reserved')
assert(la:settle('late-old',{tokens=0},'success'))
reserve_error(la,late,'late-extra',{tokens=1},'exhausted')

local bindings={principal='alice'}
local subject=compile('subjects',1,'calls',1,60,'principal')
local alice=assert(quota.open(a,function() return now end,{subjects=bindings}))
bindings.principal='bob'
check(alice:reserve(subject,'alice',{}),'host binding snapshotted')
reserve_error(alice,subject,'alice-again',{},'exhausted')
reserve_error(la,subject,'missing-subject',{},'invalid')
local bob=assert(quota.open(b,function() return now end,{subjects={principal='bob'}}))
reserve_error(bob,subject,'alice',{},'conflict')
check(bob:reserve(subject,'bob',{}),'independent bound principal bucket')

-- SQLite statement failure after bucket updates must undo the whole reserve.
assert(a:exec([[CREATE TRIGGER quota_fail BEFORE INSERT ON quota_reservations
WHEN NEW.id='sql-fail' BEGIN SELECT RAISE(ABORT,'injected failure'); END;]]))
local sql=compile('sql',1)
reserve_error(la,sql,'sql-fail',{},'database')
check(la:reserve(sql,'sql-good',{}),'database failure rolls back consumption')
assert(a:exec('DROP TRIGGER quota_fail'))
-- A live read transaction can allow BEGIN IMMEDIATE but reject COMMIT.
assert(a:exec('PRAGMA busy_timeout=0'))
assert(b:exec('BEGIN'))
assert(b:query('SELECT * FROM quota_meta'))
local commit_policy=compile('commit-lock',1)
local commit_err=reserve_error(la,commit_policy,'commit-fail',{},'database')
check(commit_err.retryable,'commit lock contention is retryable')
assert(b:exec('ROLLBACK'))
check(la:reserve(commit_policy,'commit-retry',{}),'failed commit rolls back all accounting')

local reconciliation=compile('reconciliation',10,'tokens')
assert(la:reserve(reconciliation,'reconcile',{tokens=10}))
assert(a:exec([[CREATE TRIGGER settle_fail BEFORE UPDATE ON quota_reservations
WHEN NEW.id='reconcile' BEGIN SELECT RAISE(ABORT,'settlement failure'); END;]]))
local sr,se=la:settle('reconcile',{tokens=0},'success'); refuse(sr,se,'database')
reserve_error(la,reconciliation,'refund-not-durable',{tokens=1},'exhausted')
assert(a:exec('DROP TRIGGER settle_fail'))
a:close()
a=assert(db.open(path))
la=assert(quota.open(a,function() return now end))
check(la:reserve(reconciliation,'reconcile',{tokens=10}).replayed,'pending reservation survives restart')
check(la:settle('reconcile',{tokens=0},'success'),'pending reservation settles after restart')
check(la:reserve(reconciliation,'after-reconcile',{tokens=10}),'durable reconciliation releases unused cost')

local malformed=setmetatable({tokens=0},{__index=function() error('must not execute') end})
reserve_error(la,one,'malformed',malformed,'invalid')
local v,e=la:settle('missing',{},'success'); refuse(v,e,'unknown')

local bounded=assert(policy.compile{{id='bounded',revision=1,limits={tokens=2},quotas={
 {id='tokens',metric='tokens',limit=10,window_seconds=60}}}})
reserve_error(la,bounded,'hard-limit',{tokens=3},'limit')
local partial=assert(policy.compile{{id='partial',revision=1,quotas={
 {id='a',metric='tokens',limit=10,window_seconds=60},
 {id='z',metric='cost',limit=10,window_seconds=60}}}})
assert(la:reserve(partial,'partial',{tokens=10,cost=10}))
local pr,pe=la:settle('partial',{tokens=0},'success'); refuse(pr,pe,'invalid')
reserve_error(la,partial,'partial-refund',{tokens=1,cost=0},'exhausted')
assert(la:settle('partial',{tokens=0,cost=0},'success'))
check(la:reserve(partial,'complete-refund',{tokens=10,cost=10}),'all metrics refund only on complete settlement')

local over=compile('over',10,'tokens')
assert(la:reserve(over,'overrun',{tokens=2}))
local ov=assert(la:settle('overrun',{tokens=3},'success'))
check(ov.overrun,'overrun recorded')
a:close()
a=assert(db.open(path))
la=assert(quota.open(a,function() return now end))
reserve_error(la,compile('unrelated',100),'stopped',{},'overrun')
check(la:settle('overrun',{tokens=0},'success').overrun,'overrun durable and settlement cannot erase it')
a:close(); b:close(); os.remove(path)
local closed=assert(db.open(':memory:'))
local lc=assert(quota.open(closed))
closed:close()
local r,ce=lc:reserve(one,'closed',{})
check(r==nil and ce~=nil,'closed database fails closed without raising')
-- Hard ceilings must detect contradictions even without shared quota buckets.
local harddb=assert(db.open(':memory:'))
local hard=assert(quota.open(harddb))
local hardpolicy=assert(policy.compile{{id='hard-only',revision=1,capabilities={allow={'*'}},limits={tokens=8}}})
assert(hard:reserve(hardpolicy,'hard-over',{tokens=6}))
check(hard:settle('hard-over',{tokens=7},'success').overrun,'hard-only reserved ceiling detects overrun')
local hardreopened=assert(quota.open(harddb))
reserve_error(hardreopened,one,'hard-stopped',{},'overrun')
harddb:close()
io.write('quota: ',passed,' checks passed\n')
