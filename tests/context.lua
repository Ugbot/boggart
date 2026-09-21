local context,invoke,cap,events=require('context'),require('invoke'),require('capability'),require('events')
local passed=0
local function check(ok,message) assert(ok,message); passed=passed+1 end
local authority=invoke.context{state={mode='auto',guards=false}}
local function new(values,defaults,options,auth) return context.new(values,defaults,auth or authority,options) end
local r=new({a=false,b=0,c=''},{a=true,b=2,c='default',d='fallback'})
check(r:resolve('a')==false and r:resolve('b')==0 and r:resolve('c')=='','all present falsy values override defaults')
check(r:resolve('d')=='fallback','absent falls through')
local _,err=r:resolve('missing');check(err.code=='context_missing','missing typed')
local function workflow(ctx) local c=assert(ctx:resolve('character'));return c.name end
check(workflow(new({character={name='Ada'}}))=='Ada','concrete workflow')
check(workflow(new({character=function()return {name='Ada'}end}))=='Ada','provider workflow')
local n=0
local obj={resolve=function(_,req)n=n+1;return req.value end,cache='run',revision='r1'}
r=new({x=obj},nil,{source_revisions={x='source1'}})
local value,p=r:resolve('x',{value=false});check(value==false and p.cache=='miss' and p.provider_revision=='r1' and p.source_revision=='source1','provenance false')
value,p=r:resolve('x',{value=false});check(value==false and p.cache=='hit' and n==1,'run caches false')
check(r:resolve('x',{value=7})==7 and n==2,'request variation')
new({x=obj}):resolve('x',{value=7});check(n==3,'new run isolated')
obj.revision='r2';r:resolve('x',{value=7});check(n==4,'revision change invalidates')
obj.cache='step';r:resolve('x',{value=7,step_id='a'});r:resolve('x',{step_id='a',value=7});check(n==5,'canonical key ordering step cache')
r:resolve('x',{value=7,step_id='b'});check(n==6,'distinct steps')
value,p=r:resolve('x',{value=7});check(n==7 and p.cache=='bypass' and p.cache_reason=='missing_step','missing step bypass visible')
obj.cache='run';value,p=r:resolve('x',{value=7,f=function()end});check(p.cache_reason=='unstable_request','closures not serialized')
obj.cache_key=function(_,req)return req.value end
r:resolve('x',{value=8,f=function()end});local before=n
value,p=r:resolve('x',{value=8,f=function()end});check(value==8 and p.cache=='hit' and n==before,'explicit key for closure request')
obj.cache_key=function()return false end
r:resolve('x',{value=9,f=function()end});before=n
value,p=r:resolve('x',{value=9,f=function()end});check(p.cache=='hit' and n==before,'explicit false cache key')
obj.cache_key=nil;obj.cache='none';before=n;r:resolve('x',{value=1});r:resolve('x',{value=1});check(n==before+2,'none always evaluates')
local calls=0
assert(cap.register({id='context.fixture',version='1',effect='pure'},function() calls=calls+1;return 'v1' end))
assert(cap.register({id='context.fixture',version='2',effect='pure'},function() calls=calls+1;return 'v2' end))
local pins={['context.fixture']='1'}
r=new({x=function(ctx)return ctx:call('context.fixture',{}).result end},nil,{capabilities=pins})
pins['context.fixture']='2';value,p=r:resolve('x')
check(value=='v1' and p.capabilities[1].version=='1' and p.capabilities[1].invocation_id,'host pins copied and traced')
local missing=new({x=function(ctx)local o=ctx:call('context.fixture',{});return o.error.code end})
before=calls;check(missing:resolve('x')=='capability_unpinned' and calls==before,'no implicit latest')
local denied=invoke.context{state={mode='auto',guards=false,tool_policy={['context.fixture']='deny'}}}
local denied_provider=function(ctx)local out=ctx:call('context.fixture',{});return out.error.code end
r=new({x=denied_provider},nil,{capabilities={['context.fixture']='1'}},denied)
before=calls;check(r:resolve('x')=='permission_error' and calls==before,'provider call denied')
r=new({x=function()return cap.call(nil,'context.fixture','1',{}).error.code end},nil,nil,denied)
check(r:resolve('x')=='permission_error' and calls==before,'direct mediated call inherits supplied authority from host Lua')
r=new({x={cache='run',resolve=function(ctx)return ctx:call('context.fixture',{}).status end}},nil,{capabilities={['context.fixture']='1'}})
check(r:resolve('x',{})=='succeeded','allowed cache primed')
check(invoke.with_context(denied,function()return r:resolve('x',{})end)=='failed','narrower caller cannot reuse privileged cache')
local cyc=new({a=function(ctx)return ctx:resolve('b')end,b=function(ctx)return ctx:resolve('a')end})
_,err=cyc:resolve('a');check(err.code=='context_cycle' and table.concat(err.path,' -> ')=='a -> b -> a','real dependency cycle path')
_,err=cyc:resolve('a');check(err.code=='context_cycle','stack restored after failure')
local concurrent=new({x=function(_,req)coroutine.yield('waiting');return req end})
local a=coroutine.create(function()return concurrent:resolve('x','a')end)
local b=coroutine.create(function()return concurrent:resolve('x','b')end)
check(select(2,coroutine.resume(a))=='waiting' and select(2,coroutine.resume(b))=='waiting','independent coroutines can suspend same provider')
check(select(2,coroutine.resume(a))=='a' and select(2,coroutine.resume(b))=='b','independent resolutions finish')
local secret='NEVER_LOG_THIS_CREDENTIAL'
local seen={};local h=events.on('context:resolve_*',function(_,data)seen[#seen+1]=data end)
r=new({credential=setmetatable({secret=secret},{__tostring=function()return secret end}),bad=function()error(secret)end})
value,p=r:resolve('credential');check(value.secret==secret and p.value_type=='table','concrete opaque object preserved')
_,err=r:resolve('bad');check(err.code=='context_provider_error' and not err.message:find(secret,1,true),'thrown error redacted')
events.off(h)
check(not require('json').encode(seen):find(secret,1,true),'events contain no result or exception credential')
local dep={revision='1',resolve=function()return 1 end}
r=new({a={cache='run',resolve=function(ctx)return ctx:resolve('b')end},b=dep})
value,p=r:resolve('a',{});check(value==1 and p.dependencies[1].key=='b','composition provenance')
dep.revision='2';dep.resolve=function()return 2 end
check(r:resolve('a',{})==2,'dependency revision invalidates parent cache')
-- Integer keys must not pass through lossy double formatting.
r=new({x={cache='run',resolve=function(_,req)return req.n end}})
local big=9007199254740992
check(r:resolve('x',{n=big})==big and r:resolve('x',{n=big+1})==big+1,'adjacent 64-bit integers never collide')
local cyc_request={};cyc_request.self=cyc_request
_,p=r:resolve('x',{n=1,cycle=cyc_request});check(p.cache_reason=='unstable_request','cyclic requests bypass')
_,p=r:resolve('x',{n=1,opaque=setmetatable({},{})});check(p.cache_reason=='unstable_request','opaque requests bypass')
local no_fallback=new({x=function()return nil end},{x='default'})
_,err=no_fallback:resolve('x');check(err.code=='context_missing','missing provider does not silently fall back')
local failures=0
r=new({x={cache='run',resolve=function()failures=failures+1;error('private')end}})
r:resolve('x');r:resolve('x');check(failures==2,'failures are not cached')
local ticks=0
r=new({x={cache='run',cache_key=function(ctx,req)
  check(ctx:call('context.fixture',{}).status=='succeeded','cache-key mediated call')
  return req
end,resolve=function(ctx)
  ticks=ticks+1;return ctx:call('context.fixture',{}).result
end}},nil,{capabilities={['context.fixture']='1'}})
local emitted={};h=events.on('context:resolve_after',function(_,d)emitted[#emitted+1]=d end)
local first;value,first=r:resolve('x','same');value,p=r:resolve('x','same');events.off(h)
check(ticks==1 and #first.capabilities==2 and #p.capabilities==1 and #p.cached_capabilities==2,'cache hit distinguishes current key call from evaluated calls')
check(p.evaluated_resolution_id==first.resolution_id and emitted[2].evaluated_resolution_id==emitted[1].resolution_id,'cache events correlate original evaluation')
check(p.capabilities[1].invocation_id~=p.cached_capabilities[1].invocation_id and type(p.capabilities[1].usage)=='table','usage and fresh invocation references retained')
local observed_authority
h=events.on('context:resolve_before',function()observed_authority=cap.call(nil,'context.fixture','1',{}).status end)
r=new({x=function()return 1 end},nil,nil,denied);r:resolve('x');events.off(h)
check(observed_authority=='failed','provider observers inherit authority')
local profile_calls=0
local function benign_hook()profile_calls=profile_calls+1 end
local terminals={}
h=events.on('context:resolve_after',function(_,d)terminals[#terminals+1]=d end)
r=new({x=function()error(secret,0)end})
local prior_authority=invoke.current()
debug.sethook(benign_hook,'crl',1000)
local caught,ordinary,ordinary_error=pcall(function()return r:resolve('x')end)
local restored_hook,restored_mask,restored_count=debug.gethook()
debug.sethook();events.off(h)
check(caught and ordinary==nil and ordinary_error.code=='context_provider_error','benign hook preserves typed provider error')
check(not ordinary_error.message:find(secret,1,true) and #terminals==1 and terminals[1].error_code=='context_provider_error','benign hook preserves redaction and terminal observation')
check(profile_calls>0 and restored_hook==benign_hook and restored_mask=='crl' and restored_count==1000,'hook function mask and count restored')
check(invoke.current()==prior_authority,'authority restored after profiled provider exception')
_,err=r:resolve('x');check(err.code=='context_provider_error','resolution stack restored after profiled error')
-- An enclosing instruction hook must escape the provider error conversion.
local co=coroutine.create(function()
  return new({x=function()while true do end end}):resolve('x')
end)
local hook_ticks=0
debug.sethook(co,function()hook_ticks=hook_ticks+1;if hook_ticks>1 then error('outer context budget',0)end end,'',10000)
local ok,hookerr=coroutine.resume(co)
debug.sethook(co)
check(not ok and tostring(hookerr):find('outer context budget',1,true),'enclosing hook failure is not swallowed')
local inside_budget_provider=false
local caught_budget_resolver=new({x={cache='run',resolve=function()
  inside_budget_provider=true
  pcall(function()while true do end end)
  return 'must not cache'
end}})
co=coroutine.create(function()return caught_budget_resolver:resolve('x')end)
local budget_once=false
local function once_hook()
  if inside_budget_provider and not budget_once then budget_once=true;error('one-shot budget',0)end
end
debug.sethook(co,once_hook,'',10000)
local budget_ok,budget_error=coroutine.resume(co)
local after_hook,after_mask,after_count=debug.gethook(co)
debug.sethook(co)
check(not budget_ok and tostring(budget_error):find('one-shot budget',1,true),'caught hook abort remains sticky at provider boundary')
check(after_hook==once_hook and after_mask=='' and after_count==10000,'actual abort restores original hook configuration')
local child={revision='v1',resolve=function()return 'v1' end}
local suspend=true
r=new({a={cache='run',resolve=function(ctx)
  local v=assert(ctx:resolve('b'));if suspend then coroutine.yield('pause')end;return v
end},b=child})
co=coroutine.create(function()return r:resolve('a',{})end)
check(select(2,coroutine.resume(co))=='pause','old dependency evaluation suspended')
child.revision='v2';child.resolve=function()return 'v2' end
check(r:resolve('b')=='v2','another coroutine advances source generation')
local resumed,old,oldp=coroutine.resume(co)
check(resumed and old=='v1' and oldp.cache_reason=='source_changed','in-flight old result is visibly uncached')
suspend=false
check(r:resolve('a',{})=='v2','stale in-flight result cannot poison new-generation cache')
-- Also detect host mutation during a yield without an intervening lookup.
child.revision='v3';child.resolve=function()return 'v3' end;suspend=true
co=coroutine.create(function()return r:resolve('a',{})end)
coroutine.resume(co);child.revision='v4';child.resolve=function()return 'v4' end
resumed,old,oldp=coroutine.resume(co)
check(resumed and old=='v3' and oldp.cache_reason=='source_changed','completion revalidates source generation')
suspend=false;check(r:resolve('a',{})=='v4','changed source evaluated freshly after in-flight result')
_,err=new({x={resolve=false}}):resolve('x');check(err.code=='context_invalid','reserved malformed provider field rejected')
_,err=new({x={resolve=function()end,cache='forever'}}):resolve('x');check(err.code=='context_invalid','unknown cache lifetime rejected')
_,err=new({x={resolve=function()end,revision={}}}):resolve('x');check(err.code=='context_invalid','unstable revision rejected')
local source_options={source_revisions={x='original'}}
r=new({x=1},nil,source_options);source_options.source_revisions.x='mutated'
_,p=r:resolve('x');check(p.source_revision=='original','source revision metadata copied at construction')
for _,bad in ipairs({false,{},function()end,math.huge,0/0}) do
  check(not pcall(function()new({},nil,{run_id=bad})end),'malformed run label refused')
  check(not pcall(function()new({},nil,{source_revisions={x=bad}})end),'malformed source label refused')
end
check(not pcall(function()new({},nil,{source_revisions=false})end),'malformed source map refused')
check(not pcall(function()new({},nil,{source_revisions={['']='v1'}})end),'empty source key refused')
check(new({},nil,{run_id=0,source_revisions={x=0}})~=nil,'zero metadata labels accepted')
for _,kind in ipairs({'provider','concrete','cached','missing'}) do
  local fast=kind=='concrete' and 1 or {cache=kind=='cached' and 'run' or 'none',resolve=function()return 1 end}
  local short=new(kind=='missing' and {} or {x=fast})
  if kind=='cached' then short:resolve('x') end
  local completed,count_ticks=0,0
  local thread=coroutine.create(function()
    for i=1,2000 do short:resolve('x');completed=completed+1 end
  end)
  debug.sethook(thread,function()
    count_ticks=count_ticks+1
    if count_ticks>=5 then error('short resolution budget',0)end
  end,'',10000)
  local ran,budget=coroutine.resume(thread)
  debug.sethook(thread)
  check(not ran and tostring(budget):find('short resolution budget',1,true) and completed<2000 and count_ticks>=5,
    'short '..kind..' resolutions cannot starve enclosing count budget')
end
print('context: '..passed..' checks passed')

assert(cap.register({id='context.review.uncertain',version='1',effect='pure'},function()return nil,{status='uncertain'} end))
r=new({x=function(ctx)ctx:call('context.review.uncertain',{});return nil,'private failure text' end},nil,{capabilities={['context.review.uncertain']='1'}})
local absent,typed,provenance=r:resolve('x')
check(absent==nil and typed.code=='context_provider_error' and provenance.capabilities[1].status=='uncertain','third failure return preserves observed invocation provenance')
check(not require('json').encode(provenance):find('private failure text',1,true),'failure provenance stays redacted')
print('context reviewed: '..passed..' checks passed')
