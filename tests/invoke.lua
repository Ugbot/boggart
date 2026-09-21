local invoke,tools,perm,events=require('invoke'),require('tools'),require('perm'),require('events')
local passed=0
local function check(v,msg) assert(v,msg); passed=passed+1 end
local function denied(v) return type(v)=='string' and v:find('Tool error:',1,true) end
local marker=bog.userdir..'/invocation-marker'
local st={mode='auto',guards=false,tool_policy={write='deny',bash='deny'}}
local ctx=invoke.context({state=st})
local count=0
tools.register('_effect',{effect='write',run=function() count=count+1; return 'done' end})
tools.register_body('_nested','',{},'return tools.call("write", {path=args.path,content="escaped"})')
tools.register_fallback('_fallback','',{}, {'write'})
for _,name in ipairs({'write','_nested','_fallback'}) do
  check(denied(invoke.string(ctx,name,{path=marker,content='escaped'})),'denied '..name)
end
check(sys.stat(marker)==nil,'no side effect')
invoke.with_context(ctx,function()
  check(denied(tools.get('write')({path=marker,content='escape'})),'get enters gate')
  check(denied(tools.call('write',{path=marker,content='escape'})),'call enters gate')
  check(denied(perm.wrap_run(tools.run,{mode='auto',guards=false})('write',{path=marker,content='escape'})),'wrapper cannot widen')
  local child=require('thread').agent_opts({id=1,allow={},perms={write='allow'},session={}})
  check(denied(child.run_tool('write',{path=marker,content='escape'})),'child cannot widen')
end)
check(invoke.current()==nil,'context restored')
local success=pcall(invoke.with_context,ctx,function() error('explode') end)
check(not success and invoke.current()==nil,'error restores context')
local co1=coroutine.create(function() invoke.with_context(ctx,function() coroutine.yield(); check(denied(tools.run('write',{path=marker,content='escape'})),'resumed context') end) end)
check(coroutine.resume(co1),'first coroutine yielded')
local co2=coroutine.create(function() check(tools.run('_effect')=='done','independent coroutine authority') end)
check(coroutine.resume(co2),'independent coroutine completed'); check(coroutine.resume(co1),'restricted coroutine completed')
check(count==1,'only admitted effect dispatched')
for _,code in ipairs({
  'sys.write(args.path,"escape")',
  'sys.mkdir_p(args.path)',
  'gold.fs.write(args.path,"escape")',
  'return tools.registry.write.run(args)',
  'return db.open(args.path)',
  'return data.put("x",1)',
  'return getmetatable("").__index',
  'local c=coroutine.create(function() return tools.call("write",{path=args.path,content="escape"}) end); local ok,v=coroutine.resume(c); return v',
}) do
  tools.register_body('_probe','',{},code)
  check(denied(invoke.string(ctx,'_probe',{path=marker})),'restricted generated route: '..code)
end
check(sys.stat(marker)==nil,'facade and coroutine probes have no marker')
local saved=table.insert
tools.run('lua',{code='table.insert=nil; string.foo="changed"; return 1'})
check(table.insert==saved and string.foo==nil,'stdlib tables are private copies')
local starts,ends={},{}
local h1=events.on('tool:before',function(_,e) starts[e.invocation_id]=(starts[e.invocation_id] or 0)+1; e.input.path=marker end)
local h2=events.on('tool:after',function(_,e) ends[e.invocation_id]=(ends[e.invocation_id] or 0)+1 end)
tools.register('_throw',{run=function() error('runner broke') end})
invoke.string(ctx,'write',{path=marker,content='no'})
invoke.string(ctx,'_unknown',{})
invoke.string(ctx,'_throw',{})
tools.register('_args',{run=function(a) return a.path end})
check(tools.run('_args',{path='original'})=='original','observer cannot alter dispatch args')
for id,n in pairs(starts) do check(n==1 and ends[id]==1,'exact start terminal pair') end
events.off(h1);events.off(h2)
local policy=require('policy')
local compiled=assert(policy.compile{{id='user',revision=1,capabilities={allow={'*'},deny={'_effect'}}}})
local pc=invoke.context({state={mode='auto',guards=false},policy=compiled})
check(denied(invoke.string(pc,'_effect',{})) and count==1,'generic denial')
compiled=assert(policy.compile{{id='user',revision=2,capabilities={allow={'*'}},approval=true}})
pc=invoke.context({state={mode='auto',guards=false,headless='allow'},policy=compiled})
check(denied(invoke.string(pc,'_effect',{})),'mandatory approval is not legacy headless allow')
pc=invoke.context({state={mode='auto',guards=false},policy=compiled,approve=function() return true end})
check(invoke.string(pc,'_effect',{})=='done','explicit approval')
compiled=assert(policy.compile{{id='user',revision=3,capabilities={allow={'*'}},quotas={{id='calls',metric='calls',limit=1,window_seconds=60}}}})
local quota_path=os.tmpname()
local quota_connection=assert(db.open(quota_path))
local ledger=assert(require('quota').open(quota_connection))
pc=invoke.context({state={mode='auto',guards=false},policy=compiled,ledger=ledger})
check(invoke.string(pc,'_effect',{})=='done','first quota admission')
check(denied(invoke.string(pc,'_effect',{})),'quota exhaustion')
local prior=count
local replay={reserve=function() return {id='replay',replayed=true} end}
pc=invoke.context({state={mode='auto',guards=false},policy=compiled,ledger=replay})
local _,err=invoke.call(pc,'_effect',{})
check(err.code=='replayed' and count==prior,'replayed reservation never dispatches')
pc=invoke.context({state={mode='auto',guards=false},policy=compiled})
check(denied(invoke.string(pc,'_effect',{})) and count==prior,'missing ledger fails closed')
-- Both quota scopes are admitted atomically; a child refusal cannot debit parent.
local parent_policy=assert(policy.compile{{id='atomic-parent',revision=1,capabilities={allow={'*'}},quotas={{id='calls',metric='calls',limit=1,window_seconds=60}}}})
local child_policy=assert(policy.compile{{id='atomic-child',revision=1,capabilities={allow={'*'}},quotas={{id='calls',metric='calls',limit=0,window_seconds=60}}}})
local parent=invoke.context({state={mode='auto',guards=false},policy=parent_policy,ledger=ledger})
local child=invoke.context({state={mode='auto',guards=false},policy=child_policy,ledger=ledger},parent)
check(denied(invoke.string(child,'_effect',{})),'zero child quota denied')
check(invoke.string(parent,'_effect',{})=='done','child denial did not debit parent')
local duplicate_policy=assert(policy.compile{{id='dedupe',revision=1,capabilities={allow={'*'}},quotas={{id='calls',metric='calls',limit=1,window_seconds=60}}}})
parent=invoke.context({state={mode='auto',guards=false},policy=duplicate_policy,ledger=ledger})
child=invoke.context({state={mode='auto',guards=false},policy=duplicate_policy,ledger=ledger},parent)
check(invoke.string(child,'_effect',{})=='done','same inherited quota not double charged')
local revoked={mode='auto',guards=false}
local pinned=invoke.context({state=revoked})
revoked.tool_policy={_effect='deny'}
check(denied(invoke.string(pinned,'_effect',{})),'live revocation narrows pinned context')
revoked.tool_policy=nil
local terminal_probe
local terminal_handler=events.on('tool:after',function(_,e)
  if e.name=='_args' then terminal_probe=tools.run('write',{path=marker,content='escape'}) end
end)
invoke.string(ctx,'_args',{path='ok'})
check(denied(terminal_probe) and sys.stat(marker)==nil,'terminal observer inherits caller restriction')
events.off(terminal_handler)
local broken=events.on('tool:authorize',function() error('broken authorizer') end)
prior=count
check(denied(tools.run('_effect',{})) and count==prior,'throwing authorization fails closed')
events.off(broken)
compiled=assert(policy.compile{{id='registry',revision=1,capabilities={allow={'lua'},deny={'registry.names'}}}})
pc=invoke.context({state={mode='auto',guards=false},policy=compiled})
check(denied(invoke.string(pc,'lua',{code='return tools.names()'})),'registry enumeration is mediated')
-- A candidate tools module cannot replace the cached module's private dispatcher.
tools.register('_generation',{run=function() return 'old' end})
local candidate=assert(loadfile('lua/tools.lua'))()
candidate.register('_generation',{run=function() return 'candidate' end})
check(candidate.run('_generation')=='candidate','candidate has isolated dispatcher')
check(tools.run('_generation')=='old','candidate registration cannot replace live dispatcher')
check(invoke.string(nil,'_generation')=='old','default gate resolves published registry')
local root=require('uv').fs_realpath(bog.userdir)
local scoped=assert(policy.compile{{id='resource',revision=1,capabilities={allow={'read'}},resources={path={evaluator='prefix',allow={root..'/'}}}}})
pc=invoke.context({state={mode='auto',guards=false},policy=scoped})
local _,resource_error=invoke.call(pc,'read',{path='lua/tools.lua',canonical_path=root..'/invented'})
check(resource_error and resource_error.code=='permission_error','caller resource label cannot authorize another path')
local failed_ledger={reserve=function(_,_,id) return {id=id} end,settle=function() return nil,{message='database failed'} end}
pc=invoke.context({state={mode='auto',guards=false},policy=compiled,ledger=failed_ledger})
-- compiled currently carries registry restrictions; use the existing quota policy.
pc=invoke.context({state={mode='auto',guards=false},policy=duplicate_policy,ledger=failed_ledger})
prior=count
local _,settlement_error=invoke.call(pc,'_effect',{})
check(settlement_error and settlement_error.code=='quota_settlement' and count==prior+1,'settlement error preserves failed accounting')
check(denied(invoke.string(pc,'_effect',{})) and count==prior+1,'accounting failure quarantines authority')
local cost_policy=assert(policy.compile{{id='cost',revision=1,capabilities={allow={'*'}},limits={tokens=20}}})
pc=invoke.context({state={mode='auto',guards=false},policy=cost_policy,ledger=ledger,estimate=function() return {tokens=10} end})
prior=count
local _,unsupported=invoke.call(pc,'_effect',{})
check(unsupported and unsupported.code=='unsupported_limit' and count==prior,'unsupported provider ceilings cannot dispatch')
local late_state={mode='auto',guards=false}
local late_context=invoke.context({state=late_state})
late_state.policy=cost_policy; late_state.ledger=ledger
prior=count
local _,changed=invoke.call(late_context,'_effect',{})
check(changed and changed.code=='policy_changed' and count==prior,'new live cost policy cannot be omitted by pinned context')
local broad=invoke.context({state={mode='auto',guards=false}})
invoke.with_context(ctx,function()
  invoke.with_context(broad,function()
    check(denied(tools.run('write',{path=marker,content='escape'})),'with_context cannot replace ancestor restriction')
  end)
end)
local waiting_state={mode='manual',guards=false}
local waiting=invoke.context({state=waiting_state,approve=function() coroutine.yield('approval'); return true end})
prior=count
local resumed_error
local approving=coroutine.create(function() local _,e=invoke.call(waiting,'_effect',{}); resumed_error=e end)
check(coroutine.resume(approving),'approval coroutine parked')
waiting_state.tool_policy={_effect='deny'}
check(coroutine.resume(approving),'approval coroutine resumed')
check(resumed_error and resumed_error.code=='permission_error' and count==prior,'revocation during approval prevents dispatch')
local resource='allowed'
tools.register('_resource_effect',{effect='write',resources=function() return {target=resource} end,run=function() count=count+1; return 'effect' end})
local moving_policy=assert(policy.compile{{id='moving',revision=1,capabilities={allow={'_resource_effect'}},approval=true,resources={target={allow={'allowed'}}}}})
local moving=invoke.context({state={mode='auto',guards=false},policy=moving_policy,approve=function() coroutine.yield('approval'); return true end})
local moving_error
approving=coroutine.create(function() local _,e=invoke.call(moving,'_resource_effect',{}); moving_error=e end)
check(coroutine.resume(approving),'resource approval parked')
resource='revoked'
check(coroutine.resume(approving),'resource approval resumed')
check(moving_error and moving_error.code=='permission_error' and count==prior,'resources are re-extracted after approval')
tools.register('_swap',{effect='write',run=function() return 'original' end})
local swapped_error
local swap_context=invoke.context({state={mode='manual',guards=false},approve=function() coroutine.yield('approval'); return true end})
approving=coroutine.create(function() local _,e=invoke.call(swap_context,'_swap',{}); swapped_error=e end)
check(coroutine.resume(approving),'registry approval parked')
tools.register('_swap',{effect='write',run=function() count=count+1; return 'replacement' end})
check(coroutine.resume(approving),'registry approval resumed')
check(swapped_error and swapped_error.code=='capability_changed' and count==prior,'registration change during approval cannot dispatch replacement')
-- Saved generated coroutines accumulate creator and every resumer's authority.
local function saved_body(wrapped)
  local create=wrapped and 'coroutine.wrap' or 'coroutine.create'
  local resume=wrapped and 'local value=saved()' or 'local ok,value=coroutine.resume(saved)'
  return 'if not saved then saved='..create..[[ (function()
    coroutine.yield('ready')
    while true do coroutine.yield(tools.call('write',{path=args.path,content='escaped'})) end
  end) end
  ]]..resume..'; return value'
end
for _,wrapped in ipairs({false,true}) do
  local name=wrapped and '_saved_wrap' or '_saved_resume'
  tools.register_body(name,'',{},saved_body(wrapped))
  check(invoke.string(broad,name,{path=marker})=='ready','saved coroutine starts broadly')
  check(denied(invoke.string(ctx,name,{path=marker})),'narrow resumer restricts saved coroutine')
  check(denied(invoke.string(broad,name,{path=marker})),'later broad resumer cannot erase acquired restriction')
  tools.register_body(name,'',{},saved_body(wrapped))
  check(invoke.string(ctx,name,{path=marker})=='ready','saved coroutine starts narrowly')
  check(denied(invoke.string(broad,name,{path=marker})),'broad resumer cannot erase creator restriction')
end
check(sys.stat(marker)==nil,'saved coroutine and wrap probes leave no marker')
local structured={answer=42}
tools.register('_structured',{effect='pure',run=function() return structured end})
local actual,structured_error=invoke.call(broad,'_structured',{})
check(actual==structured and not structured_error,'invoke preserves registered structured value')
check(type(tools.run('_structured'))=='string','tools.run retains legacy stringification')
tools.register('_number',{effect='pure',run=function() return 42 end})
check(invoke.call(broad,'_number',{})==42 and tools.run('_number')=='42','numeric raw result and legacy string adapter')
local child_started,child_finished=false,false
tools.register('_budget_started',{run=function() child_started=true; return 'ok' end})
tools.register('_budget_finished',{run=function() child_finished=true; return 'ok' end})
tools.register_body('_saved_budget','',{},[[
  if not saved then saved=coroutine.create(function()
    coroutine.yield('ready')
    tools.call('_budget_started')
    local x=0; for i=1,1000000 do x=x+i end
    tools.call('_budget_finished'); return 'escaped'
  end) end
  local ok,value=coroutine.resume(saved)
  return value
]])
check(tools.run('_saved_budget')=='ready','budget coroutine created in broad invocation')
local ticks=0
local function narrow_budget() ticks=ticks+1; if child_started and ticks>=20 then error('saved resumer budget exhausted',0) end end
debug.sethook(narrow_budget,'',10000)
local budget_ok,budget_error=pcall(tools.run,'_saved_budget',{})
debug.sethook()
check(not budget_ok and tostring(budget_error):find('saved resumer budget exhausted',1,true) and child_started and not child_finished,'saved coroutine loop obeys current resumer budget')
tools.register_body('_saved_close','',{},[[
  if not saved then saved=coroutine.create(function()
    local cleanup <close> = setmetatable({}, {__close=function()
      close_result=tools.call('write',{path=args.path,content='escaped'})
    end})
    coroutine.yield('ready')
  end) end
  if args.close then coroutine.close(saved); return close_result end
  local ok,value=coroutine.resume(saved); return value
]])
check(invoke.string(broad,'_saved_close',{path=marker}):find('metatables',1,true),'generated finalizer registration is refused before suspension')
check(sys.stat(marker)==nil,'refused generated finalizer never produces effect')
-- Trusted host finalizers remain supported and retain narrowed close authority.
local trusted_close_result
local trusted_finalizer=coroutine.create(function()
  local cleanup <close> = setmetatable({}, {__close=function()
    trusted_close_result=tools.call('write',{path=marker,content='escaped'})
  end})
  coroutine.yield('ready')
end)
invoke.inherit(trusted_finalizer,broad)
check(invoke.resume(trusted_finalizer),'trusted finalizer suspended')
invoke.with_context(ctx,function() check(invoke.close(trusted_finalizer),'trusted finalizer closes') end)
check(denied(trusted_close_result) and sys.stat(marker)==nil,'trusted close finalizer retains narrowed authority')
-- Repeated short resumes across invocations cannot reset an outer hook budget.
tools.register_body('_short_resume','',{},[[
  if not saved then saved=coroutine.create(function() while true do coroutine.yield('short') end end) end
  local ok,value=coroutine.resume(saved); return value
]])
check(tools.run('_short_resume')=='short','short saved coroutine created')
local charges=0
local function short_budget() charges=charges+1; if charges>=5 then error('short resumer exhausted',0) end end
debug.sethook(short_budget,'',1000000000)
local short_ok,short_error=pcall(function() for i=1,20 do tools.run('_short_resume') end end)
debug.sethook()
check(not short_ok and tostring(short_error):find('short resumer exhausted',1,true),'short resumes cannot renew outer budget')
tools.register_body('_many_yields','',{},[[
  local co=coroutine.create(function() for i=1,1000 do coroutine.yield(i) end; return 'finished' end)
  for i=1,1000 do local ok,value=coroutine.resume(co); assert(ok and value==i) end
  local ok,value=coroutine.resume(co); assert(ok); return value
]])
check(tools.run('_many_yields')=='finished','many benign yields do not duplicate hook identities')
-- Drive the actual cTUI wrapper: one prompt, event pair and ledger reserve.
local tui_gate=assert(loadfile('lua/tui/gate.lua'))()
local tui_policy=assert(policy.compile{{id='ctui-gate',revision=1,capabilities={allow={'*'}},approval=true,quotas={{id='calls',metric='calls',limit=1,window_seconds=60}}}})
local reserve_count=0
local traced_ledger={reserve=function(_,...) reserve_count=reserve_count+1; return ledger:reserve(...) end,
  settle=function(_,...) return ledger:settle(...) end}
local tui_state={mode='manual',guards=false,entries={},policy=tui_policy,ledger=traced_ledger}
tools.register('_ctui_effect',{effect='write',run=function() return 'ctui-done' end})
local starts_ctui,ends_ctui=0,0
local before_ctui=events.on('tool:before',function(_,e) if e.name=='_ctui_effect' then starts_ctui=starts_ctui+1 end end)
local after_ctui=events.on('tool:after',function(_,e) if e.name=='_ctui_effect' then ends_ctui=ends_ctui+1 end end)
local ctui_result
local ctui=coroutine.create(function() ctui_result=tui_gate.run_tool(tui_state)('_ctui_effect',{}) end)
check(coroutine.resume(ctui) and tui_state.pending~=nil,'cTUI parks once for approval')
tui_state.pending.decision='approve'
check(coroutine.resume(ctui) and coroutine.status(ctui)=='dead' and ctui_result=='ctui-done','cTUI finishes after one approval')
check(starts_ctui==1 and ends_ctui==1 and reserve_count==1,'cTUI uses one event pair and quota reserve')
events.off(before_ctui);events.off(after_ctui)
quota_connection:close()
assert(os.remove(quota_path))
print('invoke: '..passed..' passed')

-- BRAIN-16: initial and live-policy queued approval must never dispatch.
for _, profile in ipairs({"queue", "typo", false}) do
  local before=count
  local state={mode="manual",guards=false,headless=profile}
  local c=invoke.context({state=state})
  check(denied(invoke.string(c,"_effect",{})),"headless non-allow refuses admission")
  check(count==before,"headless non-allow has no effect")
end

for _, initial in ipairs({"auto","manual"}) do
  local before=count
  local live={mode=initial,guards=false,headless="allow"}
  local c=invoke.context({state=live})
  local hook=events.on("tool:authorize",function(_,event)
    if event.name=="_effect" then live.mode="manual";live.headless="queue" end
  end)
  check(denied(invoke.string(c,"_effect",{})),"new queued live approval refuses effect")
  check(count==before,"live queued admission has no effect")
  events.off(hook)
end
-- Canonical resources, including a symlink created after initial admission.
local uv=require("uv")
local dir=bog.userdir.."/brain16-allowed"
local outside=bog.userdir.."/brain16-outside"
assert(sys.mkdir_p(dir));assert(sys.mkdir_p(outside))
assert(require("util").write_file(outside.."/secret","fixture"))
local link=dir.."/escape"
assert(uv.fs_symlink(outside,link))
local pathpolicy=assert(require("policy").compile{{id="brain16-path",revision=1,
  capabilities={allow={"read","write","bash","sys.exec","sys.shell","lua"}},
  resources={path={evaluator="prefix",allow={assert(uv.fs_realpath(dir)).."/"}}}}})
local pathctx=invoke.context({state={mode="auto",guards=false,headless="allow"},policy=pathpolicy})
check(denied(invoke.string(pathctx,"read",{path=link.."/secret"})),"symlink read escapes canonical allowlist")
check(denied(invoke.string(pathctx,"write",{path=link.."/new",content="escape"})),"symlink create escapes canonical allowlist")
check(denied(invoke.string(pathctx,"bash",{command="printf escaped"})),"path authority cannot authorize shell")
for _,name in ipairs({"exec","shell"}) do
  check(denied(invoke.string(pathctx,"sys."..name,{values=table.pack("printf escaped")})),"raw shell has no invented path resource")
end
check(denied(invoke.string(pathctx,"bash",{command="printf escaped",path=dir.."/forged"})),"shell caller path label cannot grant resource authority")
assert(uv.fs_unlink(link));assert(uv.fs_symlink(dir,link))
local changed=events.on("tool:authorize",function(_,event)
  if event.name=="write" then assert(uv.fs_unlink(link));assert(uv.fs_symlink(outside,link)) end
end)
check(denied(invoke.string(pathctx,"write",{path=link.."/new",content="escaped"})),"symlink retargeted in authorization callback rechecked before dispatch")
events.off(changed)
check(not sys.stat(outside.."/new"),"symlink refused effects absent")
local _,missing_error,missing_receipt=invoke.call(pathctx,'read',{path=dir..'/absent/child'})
check(missing_error and missing_error.code=='host_capability_error' and not missing_receipt.dispatched,
  'initial missing canonical parent is a pre-dispatch capability error')
local path_state=require('perm').state();local path_headless=path_state.headless
path_state.headless='allow' -- explicitly admit the live-recheck fixture
local vanishing=dir..'/vanishing';assert(sys.mkdir_p(vanishing))
local removed=events.on('tool:authorize',function(_,event)
 if event.name=='write' then assert(uv.fs_rmdir(vanishing)) end
end)
local _,vanished_error,vanished_receipt=invoke.call(pathctx,'write',{path=vanishing..'/child',content='escaped'})
events.off(removed);path_state.headless=path_headless
check(vanished_error and vanished_error.code=='host_capability_error' and not vanished_receipt.dispatched,
  'live missing canonical parent refuses before dispatch without raw-path fallback')
check(not sys.stat(vanishing..'/child'),'missing canonical parent produced no write')
assert(uv.fs_unlink(link));sys.rmtree(dir);sys.rmtree(outside)
print("invoke BRAIN-16: "..passed.." checks passed")
