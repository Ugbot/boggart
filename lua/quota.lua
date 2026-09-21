-- Persistent, local shared quotas. Only trusted host code owns a ledger/DB.
local policy = require 'policy'
local M = {}
local MAX = 9007199254740991 -- exact integer boundary for SQLite REAL accounting
local function finite(n) return type(n)=='number' and n==n and n>=0 and n<=MAX end
local function nonempty(s) return type(s)=='string' and #s>0 end
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function fail(code, message, retryable)
  error({code=code,message=message,retryable=retryable or false}, 0)
end
local function checked(value, err)
  if value == nil then
    local message = tostring(err)
    fail('database', message, message:find('locked',1,true)~=nil or message:find('busy',1,true)~=nil)
  end
  return value
end
local function pack(values)
  local out={}
  for _,v in ipairs(values) do
    local s=type(v)=='number' and string.format('%.17g',v) or tostring(v)
    out[#out+1]=#s..':'..s
  end
  return table.concat(out)
end
local function usage(value)
  assert(plain(value), 'usage must be a plain table')
  local out={}
  for k,v in pairs(value) do
    assert(nonempty(k) and finite(v), 'usage must contain finite nonnegative amounts')
    out[k]=v
  end
  return out
end
local function protected(fn)
  local ok,result=pcall(fn)
  if ok then return result end
  if type(result)=='table' and result.code then return nil,result end
  return nil,{code='invalid',message=tostring(result),retryable=false}
end
local SCHEMA=[[
CREATE TABLE IF NOT EXISTS quota_meta (id INTEGER PRIMARY KEY CHECK(id=1), watermark REAL NOT NULL, blocked INTEGER NOT NULL);
INSERT OR IGNORE INTO quota_meta VALUES(1,0,0);
CREATE TABLE IF NOT EXISTS quota_rules (rule TEXT PRIMARY KEY, shape TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS quota_buckets (bucket TEXT PRIMARY KEY, used REAL NOT NULL CHECK(used>=0));
CREATE TABLE IF NOT EXISTS quota_reservations (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, status TEXT NOT NULL, outcome TEXT NOT NULL, overrun INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS quota_items (reservation TEXT NOT NULL, bucket TEXT NOT NULL, metric TEXT NOT NULL, amount REAL NOT NULL, PRIMARY KEY(reservation,bucket));
]]

function M.open(conn, clock, options)
  return protected(function()
    assert(type(clock or os.time)=='function', 'clock must be a function')
    clock=clock or os.time
    options=options or {}
    assert(plain(options), 'options must be plain')
    for k in pairs(options) do assert(k=='subjects','unknown ledger option') end
    local subjects={}
    assert(plain(options.subjects or {}),'subjects must be plain')
    for k,v in pairs(options.subjects or {}) do
      assert(nonempty(k) and nonempty(v),'subject bindings must be nonempty strings')
      subjects[k]=v
    end
    checked(conn:exec(SCHEMA))
    -- All transaction work is synchronous native SQLite plus private plain data.
    -- The injected clock is called before BEGIN, never while holding a lock.
    local function transaction(fn)
      return protected(function()
        checked(conn:exec('BEGIN IMMEDIATE'))
        local ok,result=pcall(function()
          local result=fn()
          checked(conn:exec('COMMIT'))
          return result
        end)
        if ok then return result end
        pcall(conn.exec,conn,'ROLLBACK')
        error(result,0)
      end)
    end
    local function query(sql,args) return checked(conn:query(sql,args)) end
    local function run(sql,args) return checked(conn:run(sql,args)) end
    local function receipt(row,replayed)
      return {id=row.id,status=row.status,outcome=row.outcome~='' and row.outcome or nil,
        overrun=row.overrun==1,replayed=replayed or false}
    end
    local ledger={}
    function ledger:reserve(compiled, invocation_id, estimate)
      local prepared,err=protected(function()
        assert(nonempty(invocation_id),'invocation ID required')
        local state=assert(policy.describe(compiled))
        estimate=usage(estimate or {})
        local now=clock()
        assert(finite(now),'clock must return finite nonnegative epoch seconds')
        local entries,identity={}, {state.revision}
        local metrics={}
        for metric in pairs(estimate) do metrics[#metrics+1]=metric end
        table.sort(metrics)
        for _,metric in ipairs(metrics) do identity[#identity+1]=pack{metric,estimate[metric]} end
        for _,q in ipairs(state.quotas) do
          assert(finite(q.limit) and finite(q.window_seconds),'quota exceeds exact accounting range')
          local subject=q.subject and subjects[q.subject] or ''
          assert(not q.subject or nonempty(subject),'missing host-bound quota subject')
          local amount=q.metric=='calls' and 1 or estimate[q.metric]
          assert(finite(amount),'bounded estimate required for '..q.metric)
          local rule=pack{q.scope_id,q.id}
          local shape=pack{q.metric,q.window_seconds,q.subject or ''}
          entries[#entries+1]={rule=rule,shape=shape,subject=subject,window=q.window_seconds,
            amount=amount,limit=q.limit,metric=q.metric}
          identity[#identity+1]=pack{rule,shape,subject,amount,q.limit}
        end
        for metric,ceiling in pairs(state.limits) do
          local amount=metric=='calls' and 1 or estimate[metric]
          assert(finite(amount),'bounded estimate required for hard limit '..metric)
          if amount>ceiling then fail('limit','hard limit exceeded: '..metric) end
        end
        return {entries=entries,fingerprint=pack(identity),now=now}
      end)
      if not prepared then return nil,err end
      return transaction(function()
        local old=query('SELECT * FROM quota_reservations WHERE id=?',{invocation_id})[1]
        if old then
          if old.fingerprint~=prepared.fingerprint then fail('conflict','invocation ID reused with different reservation') end
          return receipt(old,true)
        end
        local meta=query('SELECT * FROM quota_meta WHERE id=1')[1]
        if meta.blocked==1 then fail('overrun','ledger blocked after usage overrun') end
        local now=math.max(meta.watermark,prepared.now)
        for _,e in ipairs(prepared.entries) do
          local existing=query('SELECT shape FROM quota_rules WHERE rule=?',{e.rule})[1]
          if existing and existing.shape~=e.shape then fail('rule_changed','quota shape requires explicit migration') end
          run('INSERT OR IGNORE INTO quota_rules VALUES(?,?)',{e.rule,e.shape})
          e.bucket=pack{e.rule,e.subject,math.floor(now/e.window)*e.window}
          local bucket=query('SELECT used FROM quota_buckets WHERE bucket=?',{e.bucket})[1]
          local used=bucket and bucket.used or 0
          if e.amount>e.limit-used then fail('exhausted','quota exhausted') end
          run('INSERT OR IGNORE INTO quota_buckets VALUES(?,0)',{e.bucket})
          run('UPDATE quota_buckets SET used=used+? WHERE bucket=?',{e.amount,e.bucket})
          run('INSERT INTO quota_items VALUES(?,?,?,?)',{invocation_id,e.bucket,e.metric,e.amount})
        end
        run('UPDATE quota_meta SET watermark=? WHERE id=1',{now})
        run("INSERT INTO quota_reservations VALUES(?,?,'reserved','',0)",{invocation_id,prepared.fingerprint})
        return receipt({id=invocation_id,status='reserved',outcome='',overrun=0})
      end)
    end
    function ledger:settle(reservation_id, actual, outcome)
      local amounts,err=protected(function()
        assert(nonempty(reservation_id),'reservation ID required')
        assert(outcome=='success' or outcome=='failure' or outcome=='uncertain','invalid settlement outcome')
        return usage(actual or {})
      end)
      if not amounts then return nil,err end
      return transaction(function()
        local row=query('SELECT * FROM quota_reservations WHERE id=?',{reservation_id})[1]
        if not row then fail('unknown','unknown reservation') end
        if row.status=='settled' then return receipt(row,true) end
        local overrun=false
        for _,item in ipairs(query('SELECT * FROM quota_items WHERE reservation=?',{reservation_id})) do
          local amount=item.metric=='calls' and item.amount or amounts[item.metric]
          if amount==nil then
            if outcome=='success' then fail('invalid','actual usage required for '..item.metric) end
            amount=item.amount -- Unknown usage cannot justify a refund.
          end
          if amount>item.amount then overrun=true end
          local used=query('SELECT used FROM quota_buckets WHERE bucket=?',{item.bucket})[1].used
          if amount-item.amount>MAX-used then fail('overflow','actual usage exceeds accounting range') end
          run('UPDATE quota_buckets SET used=used+? WHERE bucket=?',{amount-item.amount,item.bucket})
        end
        if overrun then run('UPDATE quota_meta SET blocked=1 WHERE id=1') end
        run("UPDATE quota_reservations SET status='settled',outcome=?,overrun=? WHERE id=?",{outcome,overrun and 1 or 0,reservation_id})
        return receipt({id=reservation_id,status='settled',outcome=outcome,overrun=overrun and 1 or 0})
      end)
    end
    return ledger
  end)
end
return M
