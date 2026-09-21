local ast=require('mining.ast')
local workflow=require('workflow')
local passed=0
local function check(v,m) assert(v,m); passed=passed+1 end
local function index(s) local x,e=ast.index(s,'fixture-1');assert(x,e and e.message);return x end
local a='local count=1; if count > 0 then count=count+1 end; return count'
local b='local amount=1; if amount > 0 then amount=amount+1 end; return amount'
check(index(a).features.structure_hash==index(b).features.structure_hash,'local alpha equivalence')
check(index(a).features.structure_hash~=index(a:gsub('>','<')).features.structure_hash,'predicate operators differ')
check(index(a).features.structure_hash~=index(a:gsub('> 0','> 2')).features.structure_hash,'predicate literals differ')
check(index(a).source_hash==workflow.hash(a),'exact source hash')
check(index(a).source==a and index(a).version=='fixture-1','source and provenance preserved')
local src=[[local chosen = handlers[mode]
for i=1,3 do
 if i > 1 then chosen(i) end
end
return function(value) return chosen(value) end]]
local x=index(src)
local kinds={}
local exact={for_statement='for i=1,3 do\n if i > 1 then chosen(i) end\nend',
 if_statement='if i > 1 then chosen(i) end',
 function_definition='function(value) return chosen(value) end'}
for _,n in ipairs(x.nodes) do
 kinds[n.kind]=true
 if exact[n.kind] then check(src:sub(n.span.start_byte,n.span.end_byte-1)==exact[n.kind],'exact '..n.kind..' span') end
 check(n.span.start_byte>=1 and n.span.end_byte<=#src+1 and n.span.end_byte>=n.span.start_byte,'bounded source span')
end
check(kinds.for_statement and kinds.if_statement and kinds.function_definition,'loops branches closures')
check(#x.sites==2 and src:sub(x.sites[1].span.start_byte,x.sites[1].span.end_byte-1)=='chosen(i)','call exact span')
check(x.sites[1].resolution=='unknown' and #x.unknowns>0,'dynamic calls unknown')
check(#x.features.def_use>0,'lexical declaration links')
local n,e=ast.index('local x = )','bad');check(n==nil and e.code=='parse_error','syntax rejects completely')
n,e=ast.index('return 0b11','jit');check(n==nil and e.code=='parse_error','LuaJIT extensions rejected by runtime')
n,e=ast.index('return "\\q"','bad');check(n==nil and e.code=='parse_error','invalid escape rejected')
rawset(_G,'__mining_ast_executed',nil)
index('_G.__mining_ast_executed=true; while true do end')
check(rawget(_G,'__mining_ast_executed')==nil,'index never executes source')
index('global <const> answer=42; return answer')
index('global function f(... rest) return rest end; return f')
index('local <const> x=1; return x')
index('global *; return unknown')
check(index('local x=1; do local x=2; print(x) end; return x').features.structure_hash==index('local a=1; do local b=2; print(b) end; return a').features.structure_hash,'shadowing alpha equivalence')
check(index('local x=1; local x=x; return x').features.structure_hash==index('local a=1; local b=a; return b').features.structure_hash,'initializer preceding scope')
check(index('local x=1; repeat local y=x; x=y until y>0').features.structure_hash==index('local a=1; repeat local b=a; a=b until b>0').features.structure_hash,'repeat condition scope')
check(index('local function f(x) return f(x) end').features.structure_hash==index('local function g(y) return g(y) end').features.structure_hash,'recursive function scope')
check(index('local x=1; return {x=x}').features.structure_hash~=index('local y=1; return {y=y}').features.structure_hash,'field names not alpha renamed')
n,e=ast.index(string.rep(' ',262145),'large');check(n==nil and e.code=='resource_limit','source byte limit')
n,e=ast.index({},'bad');check(n==nil and e.code=='invalid_source','source input validation')
check(index('return function(... rest) return rest end').features.structure_hash==index('return function(... args) return args end').features.structure_hash,'named vararg alpha equivalence')
check(index('local obj={}; function obj:method(x) return self,x end').features.structure_hash==index('local thing={}; function thing:method(y) return self,y end').features.structure_hash,'implicit self binding')
check(index('local x=2; for x=1,x do print(x) end').features.structure_hash==index('local a=2; for b=1,a do print(b) end').features.structure_hash,'numeric loop initializer scope')
check(index('local x={}; for k,v in pairs(x) do print(k,v) end').features.structure_hash==index('local y={}; for a,b in pairs(y) do print(a,b) end').features.structure_hash,'generic loop binding')
check(index('local x=1; return function() return x end').features.def_use[1].captured,'closure capture is explicit')
check(index('global x; return function() return x end').features.def_use[1].captured==false,'declared globals are not local captures')
check(index('local x=1; return x').features.structure_hash==index('-- comment\nlocal x = 1 ; return x -- end').features.structure_hash,'comments and whitespace do not change structure')
check(index('local _ENV={}; return x').features.structure_hash~=index('local env={}; return x').features.structure_hash,'environment binding remains semantically special')
check(index('global x; return x').features.structure_hash~=index('global y; return y').features.structure_hash,'global names preserved')
check(index('global x,print; do local x=1; print(x) end; return x').features.structure_hash~=index('global y,print; do local x=1; print(x) end; return y').features.structure_hash,'global shadowing preserved')
index('local x <close> = nil; ::again:: while false do break end; repeat local y=1 until y>0')
index('return { [1]=0x1.fp+2, text=[=[long string]=], value=(3//2) << 1 | 2 ~ 1 & 7 }')
n,e=ast.index('return {'..string.rep('1,',11000)..'}','many');check(n==nil and e.code=='resource_limit','native node/work budget')
n,e=ast.index(string.rep('do ',70)..string.rep('end ',70),'deep');check(n==nil and e.code=='resource_limit','native depth budget')
n,e=ast.index('return 1',{});check(n==nil and e.code=='invalid_version','version validation')
print('mining_ast: '..passed..' checks passed')
