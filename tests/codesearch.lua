-- Real native FTS/BM25 and code_search tool over a deterministic fixture corpus.
-- Repository growth must not alter expected relevance rankings.
local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end
end
local function top_paths(rows, k)
  local s = {}
  for i = 1, math.min(k or #rows, #rows) do s[rows[i].path] = i end
  return s
end
local uv=require('uv')
local original=assert(uv.cwd())
local fixture=os.tmpname()..'_codesearch'
assert(sys.mkdir_p(fixture..'/src'))
assert(sys.mkdir_p(fixture..'/tests'))
assert(sys.mkdir_p(fixture..'/lua'))
local function write(path,content)
  local f=assert(io.open(path,'w'));assert(f:write(content));assert(f:close())
end
write(fixture..'/src/lvoice.c', 'whisper transcription voice\nwhisper transcription voice\n')
write(fixture..'/tests/voice.lua', 'whisper transcription voice\n'..string.rep('fixture assertions ',60))
write(fixture..'/lua/tools.lua', 'register_fallback adapt tool_not_found\nregister_fallback adapt tool_not_found\n')
write(fixture..'/src/other.c', 'register_fallback adapt tool_not_found\n'..string.rep('unrelated helper ',60))
write(fixture..'/README.md', string.rep('ordinary project documentation ',80))
local ok,err=xpcall(function()
  assert(uv.chdir(fixture))
  local r=bog.store.code_reindex({rebuild=true})
  check(type(r)=='table' and r.indexed==5,'native reindex indexes exactly the fixture corpus')
  check(bog.store.code_index_count()==5,'native index count matches fixture files')
  local hits=bog.store.code_search('whisper transcription voice',8)
  check(#hits==2,'voice query finds exactly both relevant fixture files')
  check(hits[1] and hits[1].path=='src/lvoice.c','most relevant voice fixture ranks first')
  check(top_paths(hits,8)['tests/voice.lua']==2,'less focused voice fixture ranks second')
  local ordered=true
  for i=2,#hits do if hits[i].score>hits[i-1].score+1e-9 then ordered=false end end
  check(ordered,'native scores are ordered best-first')
  check(hits[1] and type(hits[1].snippet)=='string' and hits[1].snippet~='','native hits carry snippets')
  local t=bog.store.code_search('register_fallback adapt tool_not_found',5)
  check(t[1] and t[1].path=='lua/tools.lua','focused fallback fixture ranks first')
  check(t[2] and t[2].path=='src/other.c','less focused fallback fixture ranks second')
  local r2=bog.store.code_reindex({})
  check(r2.indexed==0 and r2.skipped==5,'unchanged fixture corpus is entirely skipped incrementally')
  write('tests/voice.lua','revisionmarker voice fixture\n')
  -- Advance the real file mtime explicitly; no wall-clock sleeps or metadata mocks.
  assert(uv.fs_utime('tests/voice.lua',os.time()+2,os.time()+2))
  local r3=bog.store.code_reindex({})
  check(r3.indexed==1 and r3.skipped==4,'incremental index refreshes only the changed file')
  local edited=bog.store.code_search('revisionmarker',5)
  check(#edited==1 and edited[1].path=='tests/voice.lua','incremental index exposes changed content')
  check(#bog.store.code_search('',5)==0,'empty query returns no rows')
  local out=bog.tools.run('code_search',{query='whisper voice',limit=5})
  check(type(out)=='string' and out:find('src/lvoice.c',1,true),'tool returns the native fixture result')
  check(out:find('native bm25',1,true),'tool labels the native backend')
  check(bog.tools.run('code_search',{}):find('^Tool error: %[validation_error%]'),'tool requires a query')
  check(type(bog.tools.registry.code_search.fallback_chain)=='table','tool chain remains introspectable')
end,debug.traceback)
assert(uv.chdir(original))
sys.rmtree(fixture)
if not ok then error(err,0) end
if fails==0 then io.write('ok  codesearch: all assertions passed\n')
else io.write(string.format('FAILED: %d assertion(s)\n',fails));os.exit(1) end
