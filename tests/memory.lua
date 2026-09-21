-- Synthetic scoped-memory contract; no personal store or live services.
local memory=require('memory')
assert(type(memory.open)=='function','scoped memory port missing')
local json,invoke=require('json'),require('invoke')
-- A generic route 404 is not evidence that a particular indexed document was deleted.
local saved_request=http.request
http.request=function()return 404,'{}'end
assert(require('gestalt').es_request('http://fixture.invalid','DELETE','/missing/_doc/id')==nil,'generic404 is not a deletion ack')
http.request=function()return 404,'{"_index":"fixture","_id":"id","result":"not_found"}'end
assert(require('gestalt').es_request('http://fixture.invalid','DELETE','/fixture/_doc/id').result=='not_found','real ES not_found receipt accepted')
http.request=saved_request
local path=os.tmpname();local db=assert(require('db').open(path))
assert(require('evidence').configure{db=db})
assert(require('evidence_retention').configure{db=db})
local count=2
local function check(value,label)assert(value,label);count=count+1 end
local allowed,sync_allowed=true,true
local function authority(_,operation)return allowed and (operation~='sync' or sync_allowed) end
local context=invoke.context{state={mode='auto',guards=false}}
local wire,calls={},{}
local outage,ambiguous=false,false
local during_put,during_search,misroute
local function request(method,path,body)
  calls[#calls+1]={method=method,path=path,body=body}
  if outage then return nil,'fixture offline' end
  local index,id=path:match('^/([^/]+)/_doc/(.+)$')
  if id then
    wire[index]=wire[index] or {}
    if method=='DELETE' then wire[index][id]=nil;return {result='deleted',_id=id,_index=index} end
    local result=wire[index][id] and 'updated' or 'created'
    wire[index][id]=json.decode(json.encode(body))
    if during_put then local fn=during_put;during_put=nil;fn() end
    if ambiguous then ambiguous=false;return nil,'reply lost after write' end
    return {result=result,_id=id,_index=index}
  end
  index=assert(path:match('^/([^/]+)/_search$'))
  if during_search then local fn=during_search;during_search=nil;return fn() end
  local hits={}
  for key,value in pairs(wire[index] or {})do hits[#hits+1]={_id=key,_index=index,_source=value,_score=1}end
  if misroute then hits={{_id='foreign',_index='other',_source={scope='forbidden',source_id='foreign',revision=1,text='FORBIDDEN_REMOTE_PAYLOAD'}}} end
  return {hits={hits=hits,total={value=#hits}}}
end
local adapter=require('adapters.gestalt').new{scope='fixture-a',namespace='synthetic',base_url='http://fixture.invalid',request=request,capability_prefix='fixture.memory'}
local recovery_owner,remote_quiescent=nil,false
local options={db=db,scope='fixture-a',adapter=adapter,export=true,context=context,authorize=authority,
  confirm_stopped=function(token)return remote_quiescent and (token=='crashed-owner' or token==recovery_owner) end}
local port=memory.open(options)
local doc={source_id='character:ada',source_ref='fixture:novel:1',source_span={start=3,finish=9},text='Ada meets Bo',kind='character',code_version='sha256:fixture',step='scene',relation='knows',target='Bo',ast_features={calls={'scene'}},context_ref='cast@1'}
check(port:put(doc)==1,'first revision')
check(port:put(doc)==1,'identical source is idempotent')
local result=port:search('Ada',{scope='fixture-a'})
check(result.coverage.pending==1,'lag visible before sync')
local cp=port:sync()
check(cp.status=='succeeded' and cp.pending==0,'sync succeeds through invoke using shared evidence db')
result=port:search('Ada',{scope='fixture-a',filters={kind='character'}})
check(#result.hits==1 and result.hits[1].scope=='fixture-a' and result.hits[1].source_ref~=nil,'required scoped provenance scenario')
check(#adapter.index<=48,'actual index name bound')
check(result.hits[1].revision==1 and result.provenance[1].source_span.start==3,'revision and source span')
check(result.hits[1].ast_features.calls[1]=='scene','AST features preserved')
check(result.backend=='gestalt' and result.coverage.vector==false,'truthful advanced coverage')
misroute=true
local rejected=port:search('Ada')
check(rejected.backend=='local' and rejected.coverage.advanced=='unavailable','misrouted response rejected before evidence')
check(#assert(db:query("SELECT 1 FROM evidence_events WHERE body LIKE '%FORBIDDEN_REMOTE_PAYLOAD%'"))==0,'forbidden remote payload never persisted')
misroute=false
local n=#calls
check(not pcall(port.search,port,'Ada',{scope='forbidden'}),'caller scope cannot grant authority')
check(#calls==n,'forbidden scope excluded before remote retrieval')
check(not pcall(function()invoke.with_correlation({scope='forbidden'},function()port:search('Ada')end)end),'inherited invocation scope cannot be widened by host callback')
check(#calls==n,'inherited denial happens before remote retrieval')
allowed=false
check(not pcall(port.search,port,'Ada'),'host authority revocation denies local and remote')
allowed=true
during_search=function()allowed=false;return nil,'fixture permission revoked in flight' end
local fallback_allowed=pcall(port.search,port,'Ada')
allowed=true
check(not fallback_allowed,'revocation during failed remote request denies local fallback')
outage=true
result=port:search('ada',{filters={relation='knows',target='Bo'}})
check(result.backend=='local' and #result.hits==1 and result.coverage.advanced=='unavailable','useful local relationship lookup on outage')
check(#port:search('Ada',{mode='vector'}).hits==0,'no fabricated vector result')
doc.text='Ada travels';check(port:put(doc)==2,'source revision advances')
local unavailable=port:sync()
check(unavailable.pending==1,'outage keeps retry pending')
check(port:sync().status=='busy','uncertain request blocks newer remote dispatch')
recovery_owner=unavailable.owner
check(not pcall(port.recover_sync,port,recovery_owner),'local worker stopped alone cannot prove remote request quiescent')
outage=false;remote_quiescent=true;port:recover_sync(recovery_owner)
ambiguous=true
local uncertain=port:sync()
check(uncertain.status=='uncertain','lost write response remains uncertain')
recovery_owner=uncertain.owner;port:recover_sync(recovery_owner)
check(port:sync().pending==0,'quiescent retry stable id converges')
local remote_count=0;for _ in pairs(wire[adapter.index])do remote_count=remote_count+1 end
check(remote_count==1,'retry does not duplicate remote document')
-- Update while an older write is in flight: ack cannot clear newer revision.
doc.text='Ada revision three';port:put(doc)
during_put=function()doc.text='Ada revision four';port:put(doc)end
check(port:sync().pending==1,'old write cannot acknowledge new revision')
result=port:search('Ada')
check(#result.hits==0 and result.coverage.stale_rejected==1,'stale remote revision rejected')
check(port:sync().pending==0,'new revision resynchronized')
-- Crash ownership is durable, and recovery uses host proof, not a query label.
assert(db:run('INSERT INTO scoped_memory_sync VALUES(?,?)',{'fixture-a','crashed-owner'}))
local reopened=memory.open(options)
check(reopened:sync().status=='busy','reopened store retains sync owner')
check(not pcall(reopened.recover_sync,reopened,'live-owner'),'cannot steal unproven live owner')
check(reopened:recover_sync('crashed-owner'),'stopped-owner recovery')
check(reopened:sync().status=='succeeded','resumed sync works')
-- Deletion invalidates all derived records referencing the source.
local derived={source_id='process:scene',source_ref='fixture:process',source_refs={'fixture:novel:1'},text='Ada process',kind='process'}
port:put(derived);port:sync()
port:remove_source('fixture:novel:1')
check(#port:search('Ada').hits==0,'source deletion hides remote stale hits')
check(not pcall(port.put,port,doc),'source tombstone forbids resurrection')
check(port:sync().pending==0,'deletion tombstones propagated')
check(next(wire[adapter.index])==nil,'remote source and derived document deleted')
-- Sync permission can be revoked independently of read permission mid-batch.
port:put{source_id='revoke:a',source_ref='fixture:revoke:a',text='Synthetic first row'}
port:put{source_id='revoke:b',source_ref='fixture:revoke:b',text='Synthetic second row'}
local calls_before_revocation=#calls
during_put=function()sync_allowed=false end
local revoked_sync=port:sync()
sync_allowed=true
check(#calls==calls_before_revocation+1,'sync revocation after first effect prevents second dispatch while read remains allowed')
check(revoked_sync.pending==1 and revoked_sync.acknowledged==1,'revoked batch leaves undispatched row pending')
check(revoked_sync.status=='uncertain' and revoked_sync.owner~=nil,'revoked batch preserves conservative owner recovery semantics')
recovery_owner=revoked_sync.owner;port:recover_sync(recovery_owner)
check(port:sync().pending==0,'host-proven recovery resumes newly authorized sync')
port:remove('revoke:a');port:remove('revoke:b');port:sync()
-- Whole scope retention removes local payload immediately and leaves deletion work.
port:put{source_id='last',source_ref='fixture:last',text='Synthetic remaining evidence'};port:sync()
require('evidence_retention').delete_scope('fixture-a')
check(not pcall(port.search,port,'remaining'),'retention tombstone denies search')
local stored=assert(db:query('SELECT body,deleted FROM scoped_memory WHERE source_id=?',{'last'}))[1]
check(#assert(db:query("SELECT 1 FROM evidence_events WHERE body LIKE '%Ada travels%'"))==0,'retention removes data-bearing remote invocation evidence')
check(stored.body=='{}' and stored.deleted==1,'scope deletion clears indexed payload transactionally')
check(port:sync().pending==0,'retention deletion remote propagation')
-- Existing durable memory API surface remains present.
for _,name in ipairs{'list','index_text','remember','recall','forget','promote'}do check(type(memory[name])=='function','legacy '..name)end
memory.install(port)
check(not pcall(memory.search,'x',{scope='forbidden'}),'module facade preserves host authority')
print('memory: '..count..' checks passed')
db:close();os.remove(path)
