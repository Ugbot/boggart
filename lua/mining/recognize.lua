-- Trusted host API. Scope/source authority is never inferred from evidence text.
local align=require('mining.align')
local M={}
local MAX_CANDIDATES,MAX_RESULTS=32,64
local function failure(code) return nil,{code=code} end
local function admitted(ctx,scope)
 if type(scope)~='string' or scope=='' or ctx.scope~=scope then return false end
 local inherited=require('invoke').correlation()
 if inherited.scope and inherited.scope~=scope then return false end
 local ok,yes=pcall(ctx.authorize,scope,'recognize')
 local current=require('invoke').correlation()
 return ok and yes==true and ctx.scope==scope and (not current.scope or current.scope==scope)
end
local function valid(ctx,s,scope)
 if type(s)~='table' or s.scope~=scope or type(s.id)~='string' or s.revision==nil then return false end
 local ok,yes=pcall(ctx.validate,s,scope)
 return ok and yes==true and s.scope==scope
end
-- Bounded native source adapter; no full read_run/history scan and no artifact fetch.
function M.native(run_id,scope,db)
 local retention=require('evidence_retention')
 local ok,result=pcall(function()
  retention.assert_scope(db,scope)
  assert(retention.assert_run(db,run_id)==scope,'scope_mismatch')
  -- Ownership and payload are checked on the same host-selected connection.
  assert(db,'database_required')
  local rows=assert(db:query('SELECT body FROM evidence_events WHERE run_id=? ORDER BY seq LIMIT 513',{tostring(run_id)}))
  local events={};local json=require('json')
  for _,r in ipairs(rows) do events[#events+1]=json.decode(r.body) end
  local gaps=assert(db:query('SELECT reason FROM evidence_gaps WHERE run_id=? LIMIT 1',{tostring(run_id)}))
  if #gaps>0 then table.insert(events,1,{kind='coverage.incomplete',origin='derived',payload={reason=gaps[1].reason}}) end
  retention.assert_scope(db,scope);assert(retention.assert_run(db,run_id)==scope,'scope_mismatch')
  return events
 end)
 if not ok then return failure('source_unavailable') end
 return result
end
function M.find(request,context,scope)
 if type(request)~='table' or type(context)~='table' or type(context.authorize)~='function' or type(context.validate)~='function' then return failure('invalid_context') end
 if type(request.text)~='string' or #request.text>4096 then return failure('invalid_request') end
 if not admitted(context,scope) then return failure('scope_denied') end
 if request.trace and not valid(context,request.trace,scope) then return failure('request_source_unavailable') end
 local corpus=context.corpus;local retrieval={backend='host_corpus',advanced_available=false,complete=false}
 if context.retrieve then
  if type(context.retrieve)~='function' then return failure('invalid_retriever') end
  -- A host retrieval port MUST partition by scope before querying its backend.
  local ok,page=pcall(context.retrieve,request.text,{scope=scope,limit=MAX_CANDIDATES,mode='text'})
  if not admitted(context,scope) then return failure('scope_denied') end
  if not ok or type(page)~='table' or type(page.sources)~='table' then return failure('retrieval_unavailable') end
  corpus=page.sources;retrieval=page.coverage or retrieval
 end
 if type(corpus)~='table' then return failure('corpus_required') end
 local out={coverage={backend=retrieval.backend or 'host',retrieval=retrieval,semantic_available=false,vector_available=false,
  complete=false,truncated=#corpus>MAX_CANDIDATES,considered=0,rejected=0},activation_eligible=false}
 local sources={}
 for i=1,math.min(#corpus,MAX_CANDIDATES) do
  local source=corpus[i]
  if not admitted(context,scope) then return failure('scope_denied') end
  if valid(context,source,scope) then
   sources[#sources+1]=source
   local events=source.events
   if context.load then
    local ok,loaded=pcall(context.load,source,{scope=scope,limit=512})
    if not admitted(context,scope) then return failure('scope_denied') end
    if ok then events=loaded else events=nil end
   end
   if valid(context,source,scope) and type(events)=='table' then
    local candidate={id=source.id,scope=scope,revision=source.revision,source_ref=source.source_ref,code_hash=source.code_hash,events=events}
    local normalized,err=align.normalize(candidate)
    if not normalized then return nil,err end
    local comparison
    if request.trace then
     comparison,err=align.compare({request.trace,candidate},{request.ast,source.ast})
     if not comparison then return nil,err end
    end
    local coverage=comparison and comparison.variants[2].coverage or {left=0,right=0}
    local matched=comparison and comparison.variants[2].matched or 0
    local score=matched*10+math.min(coverage.left,coverage.right)
    local ast_equal=comparison and comparison.variants[2].ast_structure_equal
    if matched>0 and ast_equal~=nil then score=score+(ast_equal and .1 or -.1) end
    -- BM25 is only a tie-breaker; descriptions never establish process equivalence.
    if type(source.bm25_score)=='number' and source.bm25_score==source.bm25_score then score=score+math.max(0,math.min(source.bm25_score,1))*.01 end
    local relations=comparison and comparison.variants[2].relationships
    local applicability={eligible=false,requires={'current_context','current_resource_and_capability_versions','binding_validation','policy_admission','evaluation'},conflicts={}}
    for _,s in ipairs(normalized.steps) do
     local d=s.descriptor;local current=d and context.capabilities and context.capabilities[d.id]
     if current and (current.version~=d.version or current.effect~=d.effect or current.target~=d.target) then
      applicability.conflicts[#applicability.conflicts+1]={occurrence=s.occurrence,code='capability_changed'}
     end
    end
    if comparison and (coverage.left<1 or coverage.right<1) then applicability.conflicts[#applicability.conflicts+1]={code='observed_process_difference'} end
    if not comparison then normalized.unknowns[#normalized.unknowns+1]={code='request_structure_unavailable'} end
    if relations and relations.bindings.status=='different' then
     score=score-20;applicability.conflicts[#applicability.conflicts+1]={code='binding_relationship_difference'}
    end
    if relations and relations.contexts.status=='different' then applicability.conflicts[#applicability.conflicts+1]={code='context_dependency_variant'} end
    if ast_equal==false then applicability.conflicts[#applicability.conflicts+1]={code='ast_structure_difference'} end
    local c={id=source.id,kind='workflow',score=score,source={id=source.id,scope=scope,revision=source.revision,ref=source.source_ref,code_hash=source.code_hash},
     coverage=coverage,relationships=relations,compatibility={bindings=relations and relations.bindings.status or 'unknown',semantic_equivalence='unknown'},alignment=comparison,evidence=normalized.evidence,unknowns=comparison and comparison.unknowns or normalized.unknowns,
     tentative=matched==0,ambiguity=comparison and comparison.ambiguity or {mapping_possible='unknown',semantic_equivalence='unknown',reason='no_reference_trace'},applicability=applicability,activation_eligible=false}
    out[#out+1]=c;out.coverage.considered=out.coverage.considered+1
    if matched==0 then
     for si=1,math.min(#normalized.steps,4) do
      local step=normalized.steps[si]
      if step.origin=='imported' and #out<MAX_RESULTS then
       out[#out+1]={id=source.id..':observation:'..si,kind='fragment',tentative=true,score=0,
        source=c.source,region={occurrence=si,event_id=step.event_id},coverage={left=0,right=0},
        evidence=c.evidence,unknowns=c.unknowns,ambiguity=c.ambiguity,applicability=c.applicability,activation_eligible=false}
      end
     end
    end
    if comparison then for ri,region in ipairs(comparison.common_regions) do
     if #out>=MAX_RESULTS then out.coverage.truncated=true;break end
     local count=#region.occurrences
     if count>0 and (coverage.left<1 or coverage.right<1 or #comparison.common_regions>1) then
      out[#out+1]={id=source.id..':fragment:'..ri,kind='fragment',score=count*10,source=c.source,region=region,
       evidence=c.evidence,coverage={left=count/#comparison.traces[1].steps,right=count/#normalized.steps},
       alignment=comparison,unknowns=c.unknowns,ambiguity=c.ambiguity,applicability=applicability,activation_eligible=false}
     end
    end end
   else out.coverage.rejected=out.coverage.rejected+1 end
  else out.coverage.rejected=out.coverage.rejected+1 end
  if #out>=MAX_RESULTS then out.coverage.truncated=true;break end
 end
 -- Callback revocations invalidate already-built candidates, not just the next one.
 if not admitted(context,scope) then return failure('scope_denied') end
 if request.trace and not valid(context,request.trace,scope) then return failure('request_source_unavailable') end
 for _,s in ipairs(sources) do if not valid(context,s,scope) then return failure('source_changed') end end
 if not admitted(context,scope) then return failure('scope_denied') end
 table.sort(out,function(a,b) if a.score==b.score then return a.id<b.id end;return a.score>b.score end)
 for i,c in ipairs(out) do c.rank=i end
 return out
end
return M
